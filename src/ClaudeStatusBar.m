#import "ClaudeStatusBar.h"

#import "ClaudeProfile.h"
#import "TerminalTheme.h"

static NSTimeInterval const ClaudeUsageRefreshInterval = 5.0 * 60.0;
static NSTimeInterval const ClaudeAccountRefreshInterval = 5.0 * 60.0;

@interface ClaudeStatusBar ()
@property(nonatomic, copy, nullable) NSString *claudeExecutable;
@property(nonatomic, strong) ClaudeProfileManager *profileManager;
@property(nonatomic, strong) TerminalTheme *theme;
@property(nonatomic, strong, readwrite, nullable) ClaudeProfile *selectedProfile;
@property(nonatomic, strong) NSTextField *profileLabel;
@property(nonatomic, strong) NSTextField *usageLabel;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, strong, nullable) NSDate *lastAccountRefresh;
@property(nonatomic, strong, nullable) NSDate *lastUsageRefreshAttempt;
@property(nonatomic) BOOL accountRefreshInFlight;
@property(nonatomic) BOOL usageRefreshInFlight;
@property(nonatomic, readwrite) BOOL accountIsLoggedIn;
@property(nonatomic, readwrite) BOOL accountStatusKnown;
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

- (void)layout {
    [super layout];
    CGFloat inset = 10;
    CGFloat gap = 12;
    CGFloat availableWidth = MAX(0, NSWidth(self.bounds) - inset * 2);
    CGFloat usageWidth = MIN(availableWidth * 0.64,
                             MAX(300,
                                 self.usageLabel.intrinsicContentSize.width +
                                     24));
    CGFloat profileWidth = MAX(0, availableWidth - usageWidth - gap);
    self.profileLabel.frame =
        NSMakeRect(inset, 4, profileWidth, NSHeight(self.bounds) - 8);
    self.usageLabel.frame =
        NSMakeRect(NSWidth(self.bounds) - inset - usageWidth, 4,
                   usageWidth, NSHeight(self.bounds) - 8);
}

- (void)startMonitoring {
    [self refreshAccountIfNeeded:YES];
    [self refreshUsage];
    [self refreshUsageFromAPIIfNeeded:YES];
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
    [self refreshUsageFromAPIIfNeeded:YES];
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
    self.accountIsLoggedIn = NO;
    self.accountStatusKnown = NO;
    [self updateProfileLabel];
    [self refreshAccountIfNeeded:YES];
    [self refreshUsage];
    [self refreshUsageFromAPIIfNeeded:YES];
}

- (void)timerFired:(NSTimer *)timer {
    (void)timer;
    [self refreshAccountIfNeeded:NO];
    [self refreshUsage];
    [self refreshUsageFromAPIIfNeeded:NO];
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
        ? [NSString stringWithFormat:@"●  %@  ·  %@  ·  %@",
            profile.label, identity, plan]
        : [NSString stringWithFormat:@"●  %@  ·  %@",
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
    [self refreshUsageFromAPIIfNeeded:self.lastUsageRefreshAttempt == nil];
}

- (void)refreshUsage {
    ClaudeProfile *profile = self.selectedProfile;
    if (profile == nil) {
        self.usageLabel.stringValue = @"Usage  Select or add an account";
        self.usageLabel.textColor = self.theme.statusBarForeground;
        return;
    }

    NSDictionary *status = nil;
    NSString *sourcePath = nil;
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
                sourcePath = candidate;
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
    [styled appendAttributedString:[[NSAttributedString alloc]
        initWithString:@"Usage  " attributes:muted]];
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
    NSDictionary *attributes = [[NSFileManager defaultManager]
        attributesOfItemAtPath:sourcePath error:nil];
    NSDate *updated = attributes[NSFileModificationDate];
    if (updated != nil) {
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.timeStyle = NSDateFormatterShortStyle;
        formatter.dateStyle = NSDateFormatterNoStyle;
        [details addObject:[NSString stringWithFormat:@"Updated %@",
            [formatter stringFromDate:updated]]];
    }
    [details addObject:@"Refreshes every 5 minutes"];
    self.usageLabel.toolTip = [details componentsJoinedByString:@"\n"];
}

- (void)refreshUsageFromAPIIfNeeded:(BOOL)force {
    ClaudeProfile *profile = self.selectedProfile;
    if (profile == nil || !self.accountIsLoggedIn) return;
    if (self.usageRefreshInFlight) return;
    if (!force && self.lastUsageRefreshAttempt != nil &&
        -self.lastUsageRefreshAttempt.timeIntervalSinceNow <
            ClaudeUsageRefreshInterval) {
        return;
    }

    self.usageRefreshInFlight = YES;
    self.lastUsageRefreshAttempt = [NSDate date];
    if (![[NSFileManager defaultManager]
            fileExistsAtPath:profile.statusCachePath]) {
        self.usageLabel.stringValue = @"Usage  Refreshing…";
        self.usageLabel.textColor = self.theme.statusBarForeground;
    }

    NSString *profileID = profile.identifier;
    NSString *statusCachePath = profile.statusCachePath;
    NSString *keychainService = profile.keychainService;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSTask *keychainTask = [[NSTask alloc] init];
        keychainTask.executableURL =
            [NSURL fileURLWithPath:@"/usr/bin/security"];
        keychainTask.arguments = @[
            @"find-generic-password",
            @"-a",
            NSUserName(),
            @"-s",
            keychainService,
            @"-w",
        ];
        NSPipe *credentialsPipe = [NSPipe pipe];
        keychainTask.standardOutput = credentialsPipe;
        keychainTask.standardError = [NSFileHandle fileHandleWithNullDevice];

        NSError *keychainError = nil;
        BOOL launched =
            [keychainTask launchAndReturnError:&keychainError];
        if (launched) [keychainTask waitUntilExit];
        NSData *credentialsData = launched
            ? [credentialsPipe.fileHandleForReading readDataToEndOfFile]
            : nil;
        NSDictionary *credentials = credentialsData.length > 0
            ? [NSJSONSerialization JSONObjectWithData:credentialsData
                                               options:0
                                                 error:nil]
            : nil;
        NSDictionary *oauth =
            [credentials[@"claudeAiOauth"] isKindOfClass:NSDictionary.class]
                ? credentials[@"claudeAiOauth"]
                : nil;
        NSString *accessToken =
            [oauth[@"accessToken"] isKindOfClass:NSString.class]
                ? oauth[@"accessToken"]
                : nil;
        if (keychainError != nil || keychainTask.terminationStatus != 0 ||
            accessToken.length == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                ClaudeStatusBar *strongSelf = weakSelf;
                if (strongSelf == nil ||
                    ![strongSelf.selectedProfile.identifier
                        isEqualToString:profileID]) {
                    return;
                }
                strongSelf.usageRefreshInFlight = NO;
                [strongSelf refreshUsage];
            });
            return;
        }

        NSMutableURLRequest *request = [NSMutableURLRequest
            requestWithURL:[NSURL URLWithString:
                @"https://api.anthropic.com/api/oauth/usage"]];
        request.timeoutInterval = 15.0;
        [request setValue:[NSString stringWithFormat:@"Bearer %@", accessToken]
       forHTTPHeaderField:@"Authorization"];
        [request setValue:@"oauth-2025-04-20"
       forHTTPHeaderField:@"anthropic-beta"];
        [request setValue:@"TerminalDB/0.1"
       forHTTPHeaderField:@"User-Agent"];

        NSURLSessionDataTask *dataTask =
            [NSURLSession.sharedSession
                dataTaskWithRequest:request
                  completionHandler:^(NSData *data,
                                      NSURLResponse *response,
                                      NSError *error) {
            NSHTTPURLResponse *httpResponse =
                [response isKindOfClass:NSHTTPURLResponse.class]
                    ? (NSHTTPURLResponse *)response
                    : nil;
            NSDictionary *usage = error == nil && httpResponse.statusCode == 200
                ? [NSJSONSerialization JSONObjectWithData:data
                                                   options:0
                                                     error:nil]
                : nil;
            NSDictionary *normalized =
                [ClaudeStatusBar normalizedStatusFromUsage:usage];
            if (normalized != nil) {
                NSData *normalizedData =
                    [NSJSONSerialization dataWithJSONObject:normalized
                                                     options:0
                                                       error:nil];
                if ([normalizedData writeToFile:statusCachePath
                                      atomically:YES]) {
                    [NSFileManager.defaultManager
                        setAttributes:@{NSFilePosixPermissions : @0600}
                        ofItemAtPath:statusCachePath
                        error:nil];
                }
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                ClaudeStatusBar *strongSelf = weakSelf;
                if (strongSelf == nil ||
                    ![strongSelf.selectedProfile.identifier
                        isEqualToString:profileID]) {
                    return;
                }
                strongSelf.usageRefreshInFlight = NO;
                [strongSelf refreshUsage];
            });
        }];
        [dataTask resume];
    });
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
            [@{@"used_percentage" : utilization} mutableCopy];
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
            [@{@"used_percentage" : percent,
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
    NSNumber *fiveHourReset = limits[@"five_hour"][@"resets_at"];
    NSNumber *sevenDayReset = limits[@"seven_day"][@"resets_at"];
    NSNumber *pastReset =
        @([NSDate date].timeIntervalSince1970 - 60.0);
    return [limits[@"five_hour"][@"used_percentage"] isEqual:@12] &&
        [fiveHourReset isKindOfClass:NSNumber.class] &&
        [limits[@"seven_day"][@"used_percentage"] isEqual:@34] &&
        [sevenDayReset isKindOfClass:NSNumber.class] &&
        [limits[@"fable_five"][@"used_percentage"] isEqual:@56] &&
        [limits[@"fable_five"][@"resets_at"] isKindOfClass:NSNumber.class] &&
        [self compactResetDateTimeFromTimestamp:fiveHourReset].length > 0 &&
        [self compactResetDateTimeFromTimestamp:sevenDayReset].length > 0 &&
        [self compactResetDateTimeFromTimestamp:pastReset] == nil &&
        [self compactDateTimeFromTimestamp:pastReset].length > 0;
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
    if (timestamp != nil) {
        NSDate *reset =
            [NSDate dateWithTimeIntervalSince1970:timestamp.doubleValue];
        if (reset.timeIntervalSinceNow <= 1.0) {
            NSString *ended =
                [ClaudeStatusBar compactDateTimeFromTimestamp:timestamp]
                    ?: @"earlier";
            [segment appendAttributedString:[[NSAttributedString alloc]
                initWithString:
                    [NSString stringWithFormat:@" · ended %@", ended]
                    attributes:@{
                        NSFontAttributeName : self.usageLabel.font,
                        NSForegroundColorAttributeName :
                            self.theme.statusBarActiveForeground,
                    }]];
            return segment;
        }
    }
    NSString *resetDateTime =
        [ClaudeStatusBar compactResetDateTimeFromTimestamp:timestamp] ?: @"—";
    [segment appendAttributedString:[[NSAttributedString alloc]
        initWithString:[NSString stringWithFormat:@" ↻ %@", resetDateTime]
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
    NSString *dateTime =
        [ClaudeStatusBar compactResetDateTimeFromTimestamp:timestamp];
    if (dateTime.length == 0) {
        [descriptions addObject:[NSString stringWithFormat:
            @"%@ reported reset has passed; awaiting refreshed usage",
            label]];
        return;
    }
    [descriptions addObject:[NSString stringWithFormat:@"%@ resets %@",
        label, dateTime]];
}

@end
