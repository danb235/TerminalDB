#import "TerminalPermissions.h"

#import "TerminalInspector.h"
#import "TerminalTheme.h"

@interface TerminalPermissionCenter ()
@property(nonatomic, strong) TerminalTheme *theme;
@property(nonatomic, strong) NSMutableSet<NSString *> *sessionApprovals;
@end

@implementation TerminalPermissionCenter

static BOOL TerminalCommandMatches(NSString *command, NSString *pattern) {
    NSRegularExpression *expression =
        [NSRegularExpression regularExpressionWithPattern:pattern
                                                  options:0
                                                    error:nil];
    if (expression == nil) return NO;
    return [expression firstMatchInString:command ?: @""
                                  options:0
                                    range:NSMakeRange(0, command.length)] != nil;
}

- (instancetype)initWithTheme:(TerminalTheme *)theme {
    self = [super init];
    if (self == nil) return nil;
    _theme = theme;
    _sessionApprovals = [NSMutableSet set];
    return self;
}

- (NSUInteger)sessionApprovalCount {
    return self.sessionApprovals.count;
}

+ (NSString *)normalizedSignatureForCommand:(NSString *)command {
    NSString *trimmed = [command
        stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSArray<NSString *> *parts = [trimmed
        componentsSeparatedByCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    for (NSString *part in parts) {
        if (part.length == 0) continue;
        [tokens addObject:part.lowercaseString];
        if (tokens.count == 2) break;
    }
    return [tokens componentsJoinedByString:@" "];
}

+ (TerminalCommandRisk)riskForCommand:(NSString *)command
                          environment:(NSString *)environment {
    NSString *lower = command.lowercaseString ?: @"";
    NSString *environmentUpper = environment.uppercaseString ?: @"LOCAL";
    if ([environmentUpper containsString:@"PRODUCTION"] ||
        [environmentUpper isEqualToString:@"PROD"]) {
        return TerminalCommandRiskProduction;
    }
    NSArray<NSString *> *destructivePatterns = @[
        // Match command names at the start of any shell segment, including
        // absolute executable paths, env assignments, sudo, and runbooks.
        @"(?im)(?:^|[\\n;&|])\\s*(?:env\\s+)?(?:[A-Za-z_][A-Za-z0-9_]*=[^\\s]+\\s+)*(?:sudo\\s+)?(?:/[^\\s;&|]+/)?(?:rm|rmdir|unlink|shred|mkfs(?:\\.[^\\s]+)?|dd|truncate|shutdown|reboot|halt|poweroff|pkill|killall)\\b",
        @"(?im)(?:^|[\\n;&|])\\s*(?:sudo\\s+)?diskutil\\s+(?:erase|partition|apfs\\s+delete)\\b",
        @"(?im)(?:^|[\\n;&|])\\s*(?:/[^\\s;&|]+/)?find\\b[^\\n;&|]*(?:\\s-delete\\b|\\s-exec\\s+(?:/[^\\s;&|]+/)?rm\\b)",
        @"(?im)(?:^|[\\n;&|])\\s*(?:/[^\\s;&|]+/)?git\\b(?:\\s+-C\\s+[^\\s;&|]+)*\\s+(?:reset\\s+--hard\\b|clean\\s+-[^\\s;&|]*f)",
        @"(?im)\\b(?:drop\\s+(?:database|table)|truncate\\s+table|kubectl\\s+delete|terraform\\s+destroy)\\b",
        @"(?im)(?:^|[\\n;&|])\\s*sudo\\b",
    ];
    for (NSString *pattern in destructivePatterns) {
        if (TerminalCommandMatches(lower, pattern)) {
            return TerminalCommandRiskDestructive;
        }
    }
    NSArray<NSString *> *writePatterns = @[
        @"(?im)(?:^|[\\n;&|])\\s*(?:env\\s+)?(?:[A-Za-z_][A-Za-z0-9_]*=[^\\s]+\\s+)*(?:/[^\\s;&|]+/)?(?:mv|cp|mkdir|touch|chmod|chown|patch|tee)\\b",
        @"(?im)(?:^|[\\n;&|])\\s*(?:/[^\\s;&|]+/)?git\\b(?:\\s+-C\\s+[^\\s;&|]+)*\\s+(?:commit|push|merge|rebase|apply)\\b",
        @"(?im)\\b(?:npm|pnpm|yarn|brew|pip3?|cargo)\\s+install\\b",
        @"(?im)\\b(?:kubectl\\s+(?:apply|patch)|terraform\\s+apply|docker\\s+(?:run|compose\\s+up)|sed\\s+[^\\n;&|]*-i)\\b",
    ];
    for (NSString *pattern in writePatterns) {
        if (TerminalCommandMatches(lower, pattern)) {
            return TerminalCommandRiskWrite;
        }
    }
    if (TerminalCommandMatches(
            lower,
            @"(?m)(?:^|[^>])(?:>>?|[0-9]+>)(?!&[0-9])")) {
        return TerminalCommandRiskWrite;
    }
    NSString *validationError = nil;
    if ([TerminalInspector validateReadOnlyCommand:command
                                            error:&validationError]) {
        return TerminalCommandRiskReadOnly;
    }
    return TerminalCommandRiskUnknown;
}

+ (NSString *)titleForRisk:(TerminalCommandRisk)risk {
    switch (risk) {
        case TerminalCommandRiskReadOnly: return @"READ-ONLY";
        case TerminalCommandRiskUnknown: return @"UNKNOWN";
        case TerminalCommandRiskWrite: return @"WRITES DATA";
        case TerminalCommandRiskDestructive: return @"DESTRUCTIVE";
        case TerminalCommandRiskProduction: return @"PRODUCTION";
    }
    return @"UNKNOWN";
}

+ (NSString *)explanationForCommand:(NSString *)command
                               risk:(TerminalCommandRisk)risk {
    (void)command;
    switch (risk) {
        case TerminalCommandRiskReadOnly:
            return @"TerminalDB validated this as a bounded read-only command. "
                   "It should inspect data without changing files.";
        case TerminalCommandRiskUnknown:
            return @"TerminalDB cannot prove that this command is read-only. "
                   "Review its arguments and shell expansion carefully.";
        case TerminalCommandRiskWrite:
            return @"This command may create, replace, install, deploy, or "
                   "otherwise change local or remote state.";
        case TerminalCommandRiskDestructive:
            return @"This command contains a destructive or privileged "
                   "operation. Its effects may be difficult to reverse.";
        case TerminalCommandRiskProduction:
            return @"The active environment is production. Even a normally "
                   "safe command can expose sensitive data or affect users.";
    }
    return @"Review this command before it runs.";
}

- (NSColor *)colorForRisk:(TerminalCommandRisk)risk {
    switch (risk) {
        case TerminalCommandRiskReadOnly: return self.theme.ansiColors[2];
        case TerminalCommandRiskUnknown: return self.theme.ansiColors[3];
        case TerminalCommandRiskWrite: return self.theme.ansiColors[3];
        case TerminalCommandRiskDestructive: return self.theme.ansiColors[1];
        case TerminalCommandRiskProduction: return self.theme.ansiColors[1];
    }
    return self.theme.statusBarActiveForeground;
}

- (void)requestPermissionForCommand:(NSString *)command
                           directory:(NSString *)directory
                                host:(NSString *)host
                         environment:(NSString *)environment
                        parentWindow:(NSWindow *)parentWindow
                          completion:(void (^)(TerminalCommandPermissionDecision))
                                         completion {
    TerminalCommandRisk risk =
        [TerminalPermissionCenter riskForCommand:command
                                     environment:environment];
    NSString *signature =
        [TerminalPermissionCenter normalizedSignatureForCommand:command];
    if (risk == TerminalCommandRiskReadOnly &&
        [self.sessionApprovals containsObject:signature]) {
        completion(TerminalCommandPermissionAllowSimilarThisSession);
        return;
    }

    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle =
        risk >= TerminalCommandRiskDestructive
            ? NSAlertStyleCritical
            : (risk >= TerminalCommandRiskWrite
                ? NSAlertStyleWarning : NSAlertStyleInformational);
    alert.messageText = risk == TerminalCommandRiskReadOnly
        ? @"Run this command?"
        : @"Review command before running";
    alert.informativeText =
        [TerminalPermissionCenter explanationForCommand:command risk:risk];
    [alert addButtonWithTitle:@"Run once"];
    if (risk == TerminalCommandRiskReadOnly) {
        [alert addButtonWithTitle:@"Allow similar this session"];
    }
    [alert addButtonWithTitle:@"Cancel"];

    NSView *accessory =
        [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 500,
            risk == TerminalCommandRiskProduction
                ? 194
                : (risk >= TerminalCommandRiskDestructive ? 156 : 126))];
    NSTextField *riskLabel =
        [NSTextField labelWithString:[NSString stringWithFormat:@"●  %@",
            [TerminalPermissionCenter titleForRisk:risk]]];
    riskLabel.frame = NSMakeRect(0, NSHeight(accessory.bounds) - 22, 500, 18);
    riskLabel.font =
        [NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightSemibold];
    riskLabel.textColor = [self colorForRisk:risk];
    [accessory addSubview:riskLabel];
    NSTextField *commandLabel = [NSTextField wrappingLabelWithString:
        [NSString stringWithFormat:@"❯ %@", command]];
    commandLabel.frame =
        NSMakeRect(0, NSHeight(accessory.bounds) - 78, 500, 48);
    commandLabel.font =
        [NSFont fontWithName:self.theme.fontName size:11.5]
            ?: [NSFont monospacedSystemFontOfSize:11.5
                                           weight:NSFontWeightRegular];
    commandLabel.textColor = self.theme.terminalForeground;
    commandLabel.maximumNumberOfLines = 3;
    [accessory addSubview:commandLabel];
    NSTextField *contextLabel = [NSTextField labelWithString:
        [NSString stringWithFormat:@"⌂ %@   ·   %@   ·   %@",
            directory.length > 0 ? directory : @"~",
            host.length > 0 ? host : @"this Mac",
            environment.length > 0 ? environment : @"LOCAL"]];
    contextLabel.frame = NSMakeRect(0, NSHeight(accessory.bounds) - 104,
                                    500, 18);
    contextLabel.font =
        [NSFont monospacedSystemFontOfSize:9.5
                                    weight:NSFontWeightRegular];
    contextLabel.textColor = self.theme.statusBarActiveForeground;
    contextLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [accessory addSubview:contextLabel];

    NSButton *acknowledgement = nil;
    NSTextField *productionHostField = nil;
    if (risk >= TerminalCommandRiskDestructive) {
        acknowledgement =
            [NSButton checkboxWithTitle:
                risk == TerminalCommandRiskProduction
                    ? @"I verified the production target and understand the risk"
                    : @"I reviewed the command and understand it may be irreversible"
                               target:nil action:nil];
        acknowledgement.frame =
            NSMakeRect(0, risk == TerminalCommandRiskProduction ? 40 : 2,
                       500, 24);
        acknowledgement.contentTintColor = self.theme.ansiColors[1];
        [accessory addSubview:acknowledgement];
        if (risk == TerminalCommandRiskProduction) {
            NSTextField *instruction = [NSTextField labelWithString:
                [NSString stringWithFormat:@"Type “%@” to confirm the target",
                    host.length > 0 ? host : @"PRODUCTION"]];
            instruction.frame = NSMakeRect(0, 23, 500, 16);
            instruction.font =
                [NSFont systemFontOfSize:10 weight:NSFontWeightRegular];
            instruction.textColor = self.theme.statusBarActiveForeground;
            [accessory addSubview:instruction];
            productionHostField =
                [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 500, 22)];
            productionHostField.placeholderString =
                host.length > 0 ? host : @"PRODUCTION";
            productionHostField.font =
                [NSFont monospacedSystemFontOfSize:11
                                            weight:NSFontWeightRegular];
            [accessory addSubview:productionHostField];
        }
    }
    alert.accessoryView = accessory;
    NSButton *cancelButton = alert.buttons.lastObject;
    cancelButton.keyEquivalent = @"\r";
    alert.buttons.firstObject.keyEquivalent = @"";

    void (^finished)(NSModalResponse) = ^(NSModalResponse response) {
        if (response == NSAlertFirstButtonReturn) {
            if (acknowledgement != nil &&
                acknowledgement.state != NSControlStateValueOn) {
                NSBeep();
                completion(TerminalCommandPermissionCancel);
                return;
            }
            if (productionHostField != nil &&
                ![productionHostField.stringValue
                    isEqualToString:host.length > 0 ? host : @"PRODUCTION"]) {
                NSBeep();
                completion(TerminalCommandPermissionCancel);
                return;
            }
            completion(TerminalCommandPermissionRunOnce);
            return;
        }
        if (risk == TerminalCommandRiskReadOnly &&
            response == NSAlertSecondButtonReturn) {
            if (signature.length > 0) {
                [self.sessionApprovals addObject:signature];
            }
            completion(TerminalCommandPermissionAllowSimilarThisSession);
            return;
        }
        completion(TerminalCommandPermissionCancel);
    };
    if (parentWindow != nil) {
        [alert beginSheetModalForWindow:parentWindow
                     completionHandler:finished];
    } else {
        finished([alert runModal]);
    }
}

- (void)resetSessionApprovals {
    [self.sessionApprovals removeAllObjects];
}

+ (BOOL)runSelfTests {
    return [self riskForCommand:@"find . -name '*.jpg'"
                     environment:@"LOCAL"] == TerminalCommandRiskReadOnly &&
           [self riskForCommand:@"rm -rf build"
                     environment:@"LOCAL"] ==
                TerminalCommandRiskDestructive &&
           [self riskForCommand:@"ls"
                     environment:@"PRODUCTION"] ==
                TerminalCommandRiskProduction &&
           [self riskForCommand:@"git push"
                     environment:@"LOCAL"] == TerminalCommandRiskWrite &&
           [self riskForCommand:@"/bin/rm -rf build"
                     environment:@"LOCAL"] ==
                TerminalCommandRiskDestructive &&
           [self riskForCommand:@"find . -type f -delete"
                     environment:@"LOCAL"] ==
                TerminalCommandRiskDestructive &&
           [self riskForCommand:@"git -C repo reset --hard HEAD~1"
                     environment:@"LOCAL"] ==
                TerminalCommandRiskDestructive &&
           [self riskForCommand:@"pwd\n/bin/rm -rf build"
                     environment:@"LOCAL"] ==
                TerminalCommandRiskDestructive &&
           [self riskForCommand:@"truncate -s 0 database.sqlite"
                     environment:@"LOCAL"] ==
                TerminalCommandRiskDestructive &&
           [self riskForCommand:@"echo hello > report.txt"
                     environment:@"LOCAL"] == TerminalCommandRiskWrite &&
           [self riskForCommand:@"echo hello 2>&1"
                     environment:@"LOCAL"] != TerminalCommandRiskWrite &&
           [self riskForCommand:@"printf 'rm -rf is dangerous\\n'"
                     environment:@"LOCAL"] !=
                TerminalCommandRiskDestructive;
}

@end
