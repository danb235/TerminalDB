#import "TerminalInspector.h"

#include <signal.h>

static const NSUInteger TerminalInspectionMaximumCommandLength = 2048;
static const NSUInteger TerminalInspectionMaximumOutputBytes = 96 * 1024;
static const NSTimeInterval TerminalInspectionTimeout = 12.0;

@implementation TerminalInspector

+ (nullable NSArray<NSArray<NSString *> *> *)pipelineTokensForCommand:
    (NSString *)command error:(NSString **)error {
    NSMutableArray<NSArray<NSString *> *> *pipeline = [NSMutableArray array];
    NSMutableArray<NSString *> *segment = [NSMutableArray array];
    NSMutableString *token = [NSMutableString string];
    unichar quote = 0;
    BOOL escaping = NO;

    void (^finishToken)(void) = ^{
        if (token.length == 0) return;
        [segment addObject:[token copy]];
        [token setString:@""];
    };
    BOOL (^finishSegment)(void) = ^BOOL{
        finishToken();
        if (segment.count == 0) return NO;
        [pipeline addObject:[segment copy]];
        [segment removeAllObjects];
        return YES;
    };

    for (NSUInteger index = 0; index < command.length; index++) {
        unichar character = [command characterAtIndex:index];
        if (escaping) {
            [token appendFormat:@"%C", character];
            escaping = NO;
            continue;
        }
        if (character == '\\') {
            escaping = YES;
            continue;
        }
        if (quote != 0) {
            if (character == quote) {
                quote = 0;
            } else {
                [token appendFormat:@"%C", character];
            }
            continue;
        }
        if (character == '\'' || character == '"') {
            quote = character;
            continue;
        }
        if (character == '|') {
            if (!finishSegment()) {
                if (error != NULL) *error = @"Empty pipeline stage.";
                return nil;
            }
            continue;
        }
        if ([[NSCharacterSet whitespaceCharacterSet]
                characterIsMember:character]) {
            finishToken();
            continue;
        }
        if (character == '(' || character == ')') {
            if (error != NULL) {
                *error = @"Shell grouping is not allowed in inspections.";
            }
            return nil;
        }
        [token appendFormat:@"%C", character];
    }

    if (escaping || quote != 0) {
        if (error != NULL) *error = @"Unterminated quote or escape.";
        return nil;
    }
    if (!finishSegment()) {
        if (error != NULL) *error = @"Enter a command to inspect.";
        return nil;
    }
    if (pipeline.count > 4) {
        if (error != NULL) {
            *error = @"Inspection pipelines are limited to four stages.";
        }
        return nil;
    }
    return pipeline;
}

+ (BOOL)tokenEscapesWorkingDirectory:(NSString *)token {
    if ([token hasPrefix:@"/"] || [token hasPrefix:@"~"]) return YES;
    if ([token isEqualToString:@".."] ||
        [token hasPrefix:@"../"] ||
        [token hasSuffix:@"/.."] ||
        [token containsString:@"/../"]) {
        return YES;
    }
    return NO;
}

+ (BOOL)validateReadOnlyCommand:(NSString *)command
                          error:(NSString **)error {
    NSString *trimmed = [command stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0) {
        if (error != NULL) *error = @"Enter a command to inspect.";
        return NO;
    }
    if (trimmed.length > TerminalInspectionMaximumCommandLength) {
        if (error != NULL) *error = @"The inspection command is too long.";
        return NO;
    }

    NSCharacterSet *forbidden = [NSCharacterSet
        characterSetWithCharactersInString:@";\n\r&><`$!"];
    if ([trimmed rangeOfCharacterFromSet:forbidden].location != NSNotFound) {
        if (error != NULL) {
            *error =
                @"Redirects, substitutions, background jobs, and chained "
                 "shell statements are not allowed in inspections.";
        }
        return NO;
    }

    NSString *tokenError = nil;
    NSArray<NSArray<NSString *> *> *pipeline =
        [self pipelineTokensForCommand:trimmed error:&tokenError];
    if (pipeline == nil) {
        if (error != NULL) *error = tokenError;
        return NO;
    }

    NSSet<NSString *> *allowed = [NSSet setWithArray:@[
        @"pwd", @"ls", @"find", @"fd", @"rg", @"grep", @"egrep",
        @"fgrep", @"wc", @"head", @"tail", @"sort", @"uniq", @"cut",
        @"tr", @"stat", @"file", @"du", @"basename", @"dirname",
        @"git",
    ]];
    NSSet<NSString *> *allowedGitSubcommands = [NSSet setWithArray:@[
        @"status", @"log", @"show", @"rev-parse", @"ls-files", @"grep",
        @"describe",
    ]];
    NSSet<NSString *> *dangerousFindActions = [NSSet setWithArray:@[
        @"-delete", @"-exec", @"-execdir", @"-ok", @"-okdir",
        @"-fprint", @"-fprint0", @"-fprintf", @"-fls",
    ]];

    for (NSArray<NSString *> *tokens in pipeline) {
        NSString *executable = tokens.firstObject.lastPathComponent.lowercaseString;
        if (![allowed containsObject:executable]) {
            if (error != NULL) {
                *error = [NSString stringWithFormat:
                    @"“%@” is not approved for automatic inspection. "
                     "Paste it into the terminal to run it explicitly.",
                    executable.length > 0 ? executable : @"This command"];
            }
            return NO;
        }
        for (NSUInteger index = 1; index < tokens.count; index++) {
            NSString *token = tokens[index];
            if ([self tokenEscapesWorkingDirectory:token]) {
                if (error != NULL) {
                    *error =
                        @"Automatic inspections stay inside the current "
                         "directory. Use a relative path or paste the command "
                         "into the terminal.";
                }
                return NO;
            }
        }

        if ([executable isEqualToString:@"find"]) {
            for (NSString *token in tokens) {
                if ([dangerousFindActions
                        containsObject:token.lowercaseString] ||
                    [token.lowercaseString isEqualToString:@"-l"]) {
                    if (error != NULL) {
                        *error =
                            @"This find action can execute or modify files, "
                             "so it requires explicit terminal execution.";
                    }
                    return NO;
                }
            }
        } else if ([executable isEqualToString:@"git"]) {
            if (tokens.count < 2 ||
                ![allowedGitSubcommands
                    containsObject:tokens[1].lowercaseString]) {
                if (error != NULL) {
                    *error =
                        @"Only read-only git queries can run automatically.";
                }
                return NO;
            }
            NSSet<NSString *> *unsafeGitOptions = [NSSet setWithArray:@[
                @"--ext-diff", @"--textconv", @"--show-signature",
                @"--open-files-in-pager",
            ]];
            for (NSUInteger index = 2; index < tokens.count; index++) {
                NSString *lower = tokens[index].lowercaseString;
                if ([unsafeGitOptions containsObject:lower] ||
                    [lower hasPrefix:@"--open-files-in-pager="]) {
                    if (error != NULL) {
                        *error =
                            @"This git option can launch another process, so "
                             "it requires explicit terminal execution.";
                    }
                    return NO;
                }
            }
        } else if ([executable isEqualToString:@"fd"]) {
            for (NSString *token in tokens) {
                if ([token isEqualToString:@"-x"] ||
                    [token isEqualToString:@"-X"] ||
                    [token isEqualToString:@"--exec"] ||
                    [token hasPrefix:@"--exec="] ||
                    [token isEqualToString:@"--exec-batch"] ||
                    [token hasPrefix:@"--exec-batch="]) {
                    if (error != NULL) {
                        *error =
                            @"Running a command from fd requires explicit "
                             "terminal execution.";
                    }
                    return NO;
                }
            }
        } else if ([executable isEqualToString:@"sort"]) {
            for (NSString *token in tokens) {
                NSString *lower = token.lowercaseString;
                if ([lower isEqualToString:@"-o"] ||
                    [lower hasPrefix:@"--output"]) {
                    if (error != NULL) {
                        *error =
                            @"Writing sorted output requires explicit "
                             "terminal execution.";
                    }
                    return NO;
                }
            }
        } else if ([executable isEqualToString:@"rg"]) {
            for (NSString *token in tokens) {
                NSString *lower = token.lowercaseString;
                if ([token isEqualToString:@"-L"] ||
                    [lower isEqualToString:@"--follow"] ||
                    [lower hasPrefix:@"--pre"] ||
                    [lower hasPrefix:@"--hostname-bin"]) {
                    if (error != NULL) {
                        *error =
                            @"This ripgrep option can leave the current "
                             "directory or launch another process.";
                    }
                    return NO;
                }
            }
        } else if ([executable isEqualToString:@"tail"]) {
            for (NSString *token in tokens) {
                if ([token isEqualToString:@"-f"] ||
                    [token isEqualToString:@"-F"] ||
                    [token hasPrefix:@"--follow"]) {
                    if (error != NULL) {
                        *error =
                            @"Continuous file following is not allowed in a "
                             "bounded inspection.";
                    }
                    return NO;
                }
            }
        }
    }
    return YES;
}

- (void)runCommand:(NSString *)command
         directory:(NSString *)directory
        completion:(TerminalInspectionCompletion)completion {
    NSString *validationError = nil;
    if (![[self class] validateReadOnlyCommand:command
                                         error:&validationError]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(@{
                @"command" : command ?: @"",
                @"directory" : directory ?: @"",
                @"output" : validationError ?: @"Inspection blocked.",
                @"exit_code" : @(-1),
                @"duration" : @0,
                @"blocked" : @YES,
            });
        });
        return;
    }

    BOOL isDirectory = NO;
    if (directory.length == 0 ||
        ![NSFileManager.defaultManager
            fileExistsAtPath:directory isDirectory:&isDirectory] ||
        !isDirectory) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(@{
                @"command" : command,
                @"directory" : directory ?: @"",
                @"output" : @"The current working directory is unavailable.",
                @"exit_code" : @(-1),
                @"duration" : @0,
                @"blocked" : @YES,
            });
        });
        return;
    }

    dispatch_async(
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDate *startedAt = [NSDate date];
        NSTask *task = [[NSTask alloc] init];
        task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/sandbox-exec"];
        NSString *profile =
            @"(version 1) "
             "(allow default) "
             "(deny file-write*) "
             "(deny network*)";
        task.arguments =
            @[@"-p", profile, @"/bin/zsh", @"-f", @"-c", command];
        task.currentDirectoryURL = [NSURL fileURLWithPath:directory
                                             isDirectory:YES];
        NSMutableDictionary<NSString *, NSString *> *environment =
            [NSProcessInfo.processInfo.environment mutableCopy];
        environment[@"PATH"] =
            @"/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";
        environment[@"PAGER"] = @"cat";
        environment[@"GIT_PAGER"] = @"cat";
        environment[@"GIT_CONFIG_GLOBAL"] = @"/dev/null";
        environment[@"GIT_CONFIG_NOSYSTEM"] = @"1";
        environment[@"GIT_OPTIONAL_LOCKS"] = @"0";
        environment[@"GIT_CONFIG_COUNT"] = @"3";
        environment[@"GIT_CONFIG_KEY_0"] = @"core.fsmonitor";
        environment[@"GIT_CONFIG_VALUE_0"] = @"false";
        environment[@"GIT_CONFIG_KEY_1"] = @"core.hooksPath";
        environment[@"GIT_CONFIG_VALUE_1"] = @"/dev/null";
        environment[@"GIT_CONFIG_KEY_2"] = @"diff.external";
        environment[@"GIT_CONFIG_VALUE_2"] = @"/usr/bin/false";
        [environment removeObjectForKey:@"ZDOTDIR"];
        [environment removeObjectForKey:@"ENV"];
        [environment removeObjectForKey:@"BASH_ENV"];
        task.environment = environment;

        NSPipe *pipe = [NSPipe pipe];
        task.standardOutput = pipe;
        task.standardError = pipe;
        NSError *launchError = nil;
        if (![task launchAndReturnError:&launchError]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(@{
                    @"command" : command,
                    @"directory" : directory,
                    @"output" :
                        launchError.localizedDescription ?:
                            @"Could not start the inspection.",
                    @"exit_code" : @(-1),
                    @"duration" : @0,
                    @"blocked" : @NO,
                });
            });
            return;
        }

        __block BOOL timedOut = NO;
        __block BOOL truncated = NO;
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW,
                          (int64_t)(TerminalInspectionTimeout * NSEC_PER_SEC)),
            dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            @synchronized (task) {
                if (!task.running) return;
                timedOut = YES;
                [task terminate];
            }
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW,
                              (int64_t)(0.5 * NSEC_PER_SEC)),
                dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                @synchronized (task) {
                    if (task.running) kill(task.processIdentifier, SIGKILL);
                }
            });
        });

        NSMutableData *outputData = [NSMutableData data];
        NSFileHandle *reader = pipe.fileHandleForReading;
        while (YES) {
            NSData *chunk = [reader readDataOfLength:4096];
            if (chunk.length == 0) break;
            NSUInteger remaining =
                outputData.length < TerminalInspectionMaximumOutputBytes
                    ? TerminalInspectionMaximumOutputBytes - outputData.length
                    : 0;
            if (remaining > 0) {
                [outputData appendData:
                    chunk.length <= remaining
                        ? chunk
                        : [chunk subdataWithRange:NSMakeRange(0, remaining)]];
            }
            if (chunk.length > remaining && !truncated) {
                truncated = YES;
                @synchronized (task) {
                    if (task.running) [task terminate];
                }
            }
        }
        [task waitUntilExit];

        NSString *output =
            [[NSString alloc] initWithData:outputData
                                  encoding:NSUTF8StringEncoding];
        if (output == nil && outputData.length > 0) {
            output = @"<non-UTF-8 output omitted>";
        }
        output = [output ?: @"" stringByTrimmingCharactersInSet:
            NSCharacterSet.newlineCharacterSet];
        if (output.length == 0) output = @"(no output)";
        if (truncated) {
            output = [output stringByAppendingString:
                @"\n\n[Output truncated at 96 KB.]"];
        } else if (timedOut) {
            output = [output stringByAppendingString:
                @"\n\n[Inspection stopped after 12 seconds.]"];
        }
        NSTimeInterval duration = -startedAt.timeIntervalSinceNow;
        int status = timedOut || truncated ? -1 : task.terminationStatus;
        NSDictionary *result = @{
            @"command" : command,
            @"directory" : directory,
            @"output" : output,
            @"exit_code" : @(status),
            @"duration" : @(duration),
            @"blocked" : @NO,
            @"timed_out" : @(timedOut),
            @"truncated" : @(truncated),
        };
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(result);
        });
    });
}

@end
