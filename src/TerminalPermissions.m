#import "TerminalPermissions.h"

#import "TerminalInspector.h"
#import "TerminalTheme.h"

@interface TerminalPermissionCenter ()
@property(nonatomic, strong) TerminalTheme *theme;
@property(nonatomic, strong) NSMutableSet<NSString *> *sessionApprovals;
@end

@implementation TerminalPermissionCenter

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
    NSArray<NSString *> *destructive = @[
        @"rm ", @"rm\t", @"rmdir ", @"unlink ", @"diskutil erase",
        @"mkfs", @"dd ", @"git reset --hard", @"git clean -f",
        @"drop database", @"drop table", @"truncate table",
        @"kubectl delete", @"terraform destroy", @"sudo ",
        @"shutdown", @"reboot", @"kill -9",
    ];
    for (NSString *needle in destructive) {
        if ([lower hasPrefix:needle] ||
            [lower containsString:[@" " stringByAppendingString:needle]]) {
            return TerminalCommandRiskDestructive;
        }
    }
    NSArray<NSString *> *writes = @[
        @"mv ", @"cp ", @"mkdir ", @"touch ", @"chmod ", @"chown ",
        @"git commit", @"git push", @"git merge", @"git rebase",
        @"npm install", @"brew install", @"pip install", @"cargo install",
        @"kubectl apply", @"kubectl patch", @"terraform apply",
        @"docker run", @"docker compose up", @"sed -i", @"tee ",
    ];
    for (NSString *needle in writes) {
        if ([lower hasPrefix:needle] ||
            [lower containsString:[@" " stringByAppendingString:needle]] ||
            [lower containsString:@">"]) {
            return TerminalCommandRiskWrite;
        }
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
            risk >= TerminalCommandRiskDestructive ? 156 : 126)];
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
    if (risk >= TerminalCommandRiskDestructive) {
        acknowledgement =
            [NSButton checkboxWithTitle:
                risk == TerminalCommandRiskProduction
                    ? @"I verified the production target and understand the risk"
                    : @"I reviewed the command and understand it may be irreversible"
                               target:nil action:nil];
        acknowledgement.frame = NSMakeRect(0, 2, 500, 24);
        acknowledgement.contentTintColor = self.theme.ansiColors[1];
        [accessory addSubview:acknowledgement];
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
                     environment:@"LOCAL"] == TerminalCommandRiskWrite;
}

@end
