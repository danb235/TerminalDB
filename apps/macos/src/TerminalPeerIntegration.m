#import "TerminalPreferences.h"
#import "TerminalApplication.h"
#import "TerminalPeerStores.h"
#include <unistd.h>

BOOL TerminalDBRunsSessionHost(void) {
    return [NSProcessInfo.processInfo.arguments containsObject:@"--session-host"] ||
        [NSProcessInfo.processInfo.processName isEqualToString:@"TerminalDBSessionHost"];
}

BOOL TerminalDBUsesPeerSessions(void) {
    NSArray *arguments = NSProcessInfo.processInfo.arguments;
    for (NSString *flag in @[@"--self-test", @"--background-tab-qa", @"--visual-qa", @"--terminal-qa"]) {
        if ([arguments containsObject:flag]) return NO;
    }
    return !TerminalDBRunsSessionHost();
}

static NSString *PeerBoundedText(NSString *text, NSUInteger limit) {
    if (![text isKindOfClass:NSString.class]) return @"";
    return text.length > limit ? [text substringFromIndex:text.length - limit] : text;
}

@implementation AppDelegate (PeerIntegration)

- (NSDictionary *)peerSessionState {
    NSMutableArray *accounts = [NSMutableArray array];
    for (ClaudeProfile *profile in self.profileManager.profiles) {
        [accounts addObject:[[self rootController] remoteUsageForProfile:profile]];
    }
    NSMutableArray *records = [NSMutableArray array];
    NSArray *allRecords = self.ledgerStore.records;
    for (NSUInteger index = 0; index < MIN((NSUInteger)50, allRecords.count); index++) {
        NSMutableDictionary *record = [allRecords[index] mutableCopy];
        record[@"output"] = PeerBoundedText(record[@"output"], 1000);
        [records addObject:record];
    }
    return @{
        @"sessionId": self.terminalSessionIdentifier ?: @"",
        @"title": self.window.tab.title ?: @"Terminal",
        @"host": NSHost.currentHost.localizedName ?: @"Mac",
        @"directory": [self currentAssistantDirectory],
        @"rows": @(self.terminalRows), @"columns": @(self.terminalColumns),
        @"busy": @(self.tabIsBusy), @"command": self.activeLedgerCommand ?: @"",
        @"private": @(self.privateSession),
        @"permissionMode": [TerminalDBPreferences() stringForKey:@"TerminalDBPermissionMode"] ?: @"ask",
        @"accountId": self.selectedProfile.identifier ?: @"",
        @"accounts": accounts, @"records": records, @"ledgerCount": @(allRecords.count),
        @"usageState": [self.claudeStatusBar peerUsagePresentation],
        @"record": self.ledgerBar.currentRecord ?: @{},
        @"provider": self.apiConfiguration.chatProvider ?: @"",
        @"model": self.claudeModelName ?: @"",
        @"apiModel": self.apiConfiguration.selectedModelID ?: @"",
        @"subscriptionModel": self.apiConfiguration.subscriptionModelID ?: @"",
        @"models": self.apiConfiguration.models ?: @[],
        @"hasAPIKey": @(self.apiConfiguration.hasAPIKey),
        @"assistant": [self.assistantView peerPresentation],
    };
}

- (void)publishPeerState {
    if (!TerminalDBRunsSessionHost() || self.terminalSessionIdentifier.length == 0) return;
    NSDictionary *state = [self peerSessionState];
    if ([state isEqual:self.peerLastPublishedState]) return;
    self.peerLastPublishedState = state;
    [[self rootController].sessionServer publish:@{
        @"type": @"state", @"sessionId": self.terminalSessionIdentifier,
        @"state": state,
    }];
}

- (void)startSessionHost {
    self.sessionServer = [[TDBSessionServer alloc] init];
    self.peerApprovals = [NSMutableDictionary dictionary];
    __weak AppDelegate *weakRoot = self;
    self.sessionServer.requestHandler = ^(NSDictionary *request, void (^reply)(NSDictionary *)) {
        @try { [weakRoot handlePeerHostRequest:request reply:reply]; }
        @catch (NSException *exception) { reply(@{@"error": @"The workstation rejected a malformed operation."}); }
    };
    [NSNotificationCenter.defaultCenter addObserverForName:TerminalLedgerDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        [weakRoot.sessionServer publish:@{@"type": @"ledger.changed"}];
    }];
    NSError *error = nil;
    if (![self.sessionServer startAndReturnError:&error]) {
        // No request bodies, keys, terminal output, or provider configuration
        // enter helper diagnostics.
        fprintf(stderr, "TerminalDB session service could not start.\n");
        [NSApp terminate:nil];
    }
}

- (void)handlePeerHostRequest:(NSDictionary *)request reply:(void (^)(NSDictionary *))reply {
    NSString *operation = request[@"operation"];
    NSString *identifier = request[@"sessionId"];
    AppDelegate *root = [self rootController];
    AppDelegate *controller = [root terminalControllerForSessionIdentifier:identifier];
    if ([operation isEqualToString:@"session.list"]) {
        NSMutableArray *sessions = [NSMutableArray array];
        for (AppDelegate *item in root.windowControllers) {
            [sessions addObject:@{@"sessionId": item.terminalSessionIdentifier,
                @"title": item.window.tab.title ?: @"Terminal",
                @"directory": [item currentAssistantDirectory], @"busy": @(item.tabIsBusy)}];
        }
        reply(@{@"sessions": sessions}); return;
    }
    if ([operation isEqualToString:@"session.create"]) {
        if (root.windowControllers.count >= 32) { reply(@{@"error": @"This workstation has reached its 32-session limit. End an unused session first."}); return; }
        NSString *directory = request[@"directory"];
        if (![directory isKindOfClass:NSString.class] || directory.length == 0 || [directory isEqualToString:@"~"]) directory = NSHomeDirectory();
        BOOL isDirectory = NO;
        if (![NSFileManager.defaultManager fileExistsAtPath:directory isDirectory:&isDirectory] || !isDirectory) {
            reply(@{@"error": @"That directory does not exist on this workstation."}); return;
        }
        root.peerStartDirectory = directory;
        controller = [root createTerminalController];
        if ([request[@"private"] boolValue]) controller.privateSession = YES;
        root.peerStartDirectory = nil;
        reply([controller peerSessionState]); return;
    }
    if (controller == nil) { reply(@{@"error": @"This session has ended or is no longer available.", @"code": @"session-unavailable"}); return; }
    if ([operation isEqualToString:@"session.attach"] || [operation isEqualToString:@"host.state"]) {
        reply([controller peerSessionState]); return;
    }
    if ([operation isEqualToString:@"session.snapshot"]) {
        NSString *recipient = request[@"deliveryClientId"];
        NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 2;
        __block void (^sendSnapshot)(void);
        sendSnapshot = ^{
            if (!controller.terminalView.snapshotReady && NSProcessInfo.processInfo.systemUptime < deadline) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC), dispatch_get_main_queue(), sendSnapshot); return;
            }
            if (!controller.terminalView.snapshotReady) {
                reply(@{@"error": @"A large terminal control sequence is still arriving. Reconnect after output settles."}); sendSnapshot = nil; return;
            }
            NSData *data = [controller.terminalView ansiSnapshotData];
            NSString *snapshot = NSUUID.UUID.UUIDString;
            [root.sessionServer publishToClient:@{@"type": @"snapshot.begin", @"sessionId": identifier, @"snapshotId": snapshot} clientID:recipient];
            for (NSUInteger offset = 0; offset < data.length; offset += 128 * 1024) {
                NSData *chunk = [data subdataWithRange:NSMakeRange(offset, MIN(128 * 1024, data.length - offset))];
                [root.sessionServer publishToClient:@{@"type": @"snapshot.chunk", @"sessionId": identifier,
                    @"snapshotId": snapshot, @"data": [chunk base64EncodedStringWithOptions:0]} clientID:recipient];
            }
            [root.sessionServer publishToClient:@{@"type": @"snapshot.end", @"sessionId": identifier, @"snapshotId": snapshot} clientID:recipient];
            reply(@{@"accepted": @YES}); sendSnapshot = nil;
        };
        sendSnapshot(); return;
    }
    if ([operation isEqualToString:@"terminal.input"]) {
        NSData *data = [[NSData alloc] initWithBase64EncodedString:request[@"data"] ?: @"" options:0];
        if (data == nil || data.length > 512000 || controller.pty < 0 ||
            ![controller.terminalView enqueueInputData:data]) {
            reply(@{@"error": @"The terminal could not accept the complete input."}); return;
        }
        reply(@{@"accepted": @YES}); return;
    }
    if ([operation isEqualToString:@"terminal.resize"]) {
        controller.controllerGeometryActive = YES;
        BOOL accepted = [controller applyControllerColumns:[request[@"columns"] unsignedIntegerValue]
                                                          rows:[request[@"rows"] unsignedIntegerValue]];
        if (accepted) [controller publishPeerState];
        reply(accepted ? @{@"accepted": @YES} : @{@"error": @"The terminal size is outside supported limits."}); return;
    }
    if ([operation isEqualToString:@"terminal.focus"]) {
        [controller.terminalView setTerminalFocus:[request[@"focused"] boolValue]];
        reply(@{@"accepted": @YES}); return;
    }
    if ([operation isEqualToString:@"session.end"]) {
        [controller.window close]; reply(@{@"accepted": @YES}); return;
    }
    if ([operation isEqualToString:@"workspace.restoreSession"]) {
        NSDictionary *snapshot = request[@"snapshot"];
        if (![snapshot isKindOfClass:NSDictionary.class] || [controller hasForegroundProcessInThisPane]) {
            reply(@{@"error": @"This saved conversation can only be restored at an idle shell prompt."}); return;
        }
        ClaudeProfile *profile = [root.profileManager profileWithIdentifier:snapshot[@"account_id"] ?: @""];
        if (!profile) for (ClaudeProfile *candidate in root.profileManager.profiles)
            if ([candidate.label isEqual:snapshot[@"account_label"]]) { profile = candidate; break; }
        if (profile) [controller claudeStatusBar:controller.claudeStatusBar didSelectProfile:profile];
        NSMutableArray *messages = [NSMutableArray array];
        for (id message in [snapshot[@"chat_messages"] isKindOfClass:NSArray.class] ? snapshot[@"chat_messages"] : @[]) {
            if ([message isKindOfClass:NSDictionary.class] && [message[@"role"] isKindOfClass:NSString.class] && [message[@"content"] isKindOfClass:NSString.class]) [messages addObject:message];
        }
        controller.assistantMessages = messages; [controller trimAssistantConversationIfNeeded];
        controller.assistantSubscriptionSessionID = [snapshot[@"subscription_session_id"] isKindOfClass:NSString.class] ? snapshot[@"subscription_session_id"] : nil;
        [controller.assistantView beginWithModelName:[controller assistantModelDisplayName] messages:controller.assistantMessages];
        [controller.assistantView finish]; [controller publishPeerState];
        reply(@{@"accepted": @YES}); return;
    }
    if ([operation isEqualToString:@"assistant.send"]) {
        [controller.assistantView setContextItems:request[@"contextItems"] ?: @[]];
        [controller beginAssistantRequestForPrompt:request[@"prompt"] ?: @""];
        reply(@{@"accepted": @YES}); return;
    }
    if ([operation isEqualToString:@"assistant.reset"]) {
        [controller resetAssistantConversation]; reply(@{@"accepted": @YES}); return;
    }
    if ([operation isEqualToString:@"ledger.query"]) {
        NSArray *records = [controller.ledgerStore recordsMatching:request[@"query"] ?: @"" filters:request[@"filters"]];
        NSUInteger offset = MIN(records.count, [request[@"offset"] unsignedIntegerValue]);
        NSMutableArray *page = [NSMutableArray array];
        for (NSUInteger i = offset; i < MIN(records.count, offset + 25); i++) {
            NSMutableDictionary *item = [records[i] mutableCopy];
            if ([item[@"output"] length] > 128000) { item[@"output"] = PeerBoundedText(item[@"output"], 128000); item[@"truncated"] = @YES; }
            [page addObject:item];
            if ([NSJSONSerialization dataWithJSONObject:page options:0 error:nil].length > 512000) { [page removeLastObject]; break; }
        }
        reply(@{@"records": page, @"total": @(records.count)}); return;
    }
    if ([operation isEqualToString:@"project.files"]) {
        TerminalProductWindowController *tools = [[TerminalProductWindowController alloc] initWithTheme:controller.theme store:controller.productStore];
        reply(@{@"items": [tools projectItemsForPeerDirectory:[controller currentAssistantDirectory]]}); return;
    }
    if ([operation isEqualToString:@"product.list"]) {
        NSString *kind = request[@"kind"];
        NSArray *items = [kind isEqual:@"runbooks"] ? controller.productStore.runbooks :
            [kind isEqual:@"workspaces"] ? controller.productStore.workspaces :
            [kind isEqual:@"monitors"] ? controller.productStore.monitors : nil;
        if (!items) { reply(@{@"error": @"Unknown workstation collection."}); return; }
        NSUInteger offset = MIN(items.count, [request[@"offset"] unsignedIntegerValue]);
        NSMutableArray *page = [NSMutableArray array];
        for (NSUInteger i = offset; i < MIN(items.count, offset + 25); i++) {
            [page addObject:items[i]];
            if (page.count > 1 && [NSJSONSerialization dataWithJSONObject:page options:0 error:nil].length > 512000) { [page removeLastObject]; break; }
        }
        reply(@{@"items": page, @"total": @(items.count)}); return;
    }
    if ([operation isEqualToString:@"project.preview"]) {
        NSString *path = [request[@"path"] stringByResolvingSymlinksInPath];
        NSString *directory = [[controller currentAssistantDirectory] stringByResolvingSymlinksInPath];
        NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
        if (![path hasPrefix:[directory stringByAppendingString:@"/"]] ||
            ![attributes[NSFileType] isEqual:NSFileTypeRegular] || [attributes[NSFileSize] unsignedLongLongValue] > 256 * 1024) {
            reply(@{@"error": @"This file is outside the project or too large to preview."}); return;
        }
        NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        reply(@{@"preview": PeerBoundedText(text ?: @"Binary or non-UTF-8 file", 16000)}); return;
    }
    if ([operation isEqualToString:@"ledger.bookmark"]) {
        [controller.ledgerStore toggleBookmarkForRecord:request[@"recordId"] ?: @""];
    } else if ([operation isEqualToString:@"ledger.clear"]) {
        [controller.ledgerStore clearHistory];
    } else if ([operation isEqualToString:@"private.set"]) {
        controller.privateSession = [request[@"enabled"] boolValue];
    } else if ([operation isEqualToString:@"account.select"]) {
        ClaudeProfile *profile = [root.profileManager profileWithIdentifier:request[@"accountId"] ?: @""];
        if ([controller hasForegroundProcessInThisPane]) { reply(@{@"error": @"Wait for the active command to finish before changing Claude accounts."}); return; }
        [controller claudeStatusBar:controller.claudeStatusBar didSelectProfile:profile];
    } else if ([operation isEqualToString:@"account.add"]) {
        BOOL busy = [controller hasForegroundProcessInThisPane];
        NSError *error = nil;
        ClaudeProfile *profile = [root.profileManager createProfileWithLabel:request[@"label"] ?: @"Claude" error:&error];
        if (!profile) { reply(@{@"error": @"The workstation could not create that Claude profile."}); return; }
        if (!busy) {
            controller.selectedProfile = profile; [controller writeWindowProfileFile];
            [controller.claudeStatusBar selectProfile:profile];
        }
        [controller publishPeerState]; reply(@{@"accountId": profile.identifier, @"busy": @(busy)}); return;
    } else if ([operation isEqualToString:@"account.remove"]) {
        ClaudeProfile *profile = [root.profileManager profileWithIdentifier:request[@"accountId"] ?: @""];
        for (AppDelegate *view in root.windowControllers) {
            if ([view.selectedProfile.identifier isEqual:profile.identifier] && [view hasForegroundProcessInThisPane]) {
                reply(@{@"error": @"A session using this Claude account is busy. Wait for its shell prompt before removing it."}); return;
            }
        }
        if (!profile || ![root.profileManager removeProfile:profile error:nil]) {
            reply(@{@"error": @"The workstation could not remove that Claude profile."}); return;
        }
        for (AppDelegate *view in root.windowControllers) {
            if ([view.selectedProfile.identifier isEqual:profile.identifier]) {
                view.selectedProfile = root.profileManager.lastSelectedProfile;
                [view.claudeStatusBar selectProfile:view.selectedProfile]; [view writeWindowProfileFile];
                [view resetAssistantConversation]; [view publishPeerState];
            }
        }
    } else if ([operation isEqualToString:@"account.refresh"]) {
        [controller.claudeStatusBar refreshNow];
    } else if ([operation isEqualToString:@"account.login"]) {
        ClaudeProfile *profile = [root.profileManager profileWithIdentifier:request[@"accountId"] ?: @""];
        if ([controller hasForegroundProcessInThisPane] && ![controller canRestartTrackedClaudeLoginForProfile:profile]) {
            reply(@{@"error": @"This session is busy. Open sign-in in another tab.", @"code": @"session-busy"}); return;
        }
        if (!profile || controller.claudeExecutable.length == 0) {
            reply(@{@"error": @"Select a Claude profile, install Claude Code on this workstation, and wait for its shell prompt before signing in."}); return;
        }
        [controller startClaudeLoginForProfile:profile];
        [controller.window orderOut:nil];
    } else if ([operation isEqualToString:@"settings.update"]) {
        if ([@[@"ask", @"read-only", @"paste-only"] containsObject:request[@"permissionMode"]])
            [TerminalDBPreferences() setObject:request[@"permissionMode"] forKey:@"TerminalDBPermissionMode"];
        if (request[@"provider"]) [controller.apiConfiguration selectChatProvider:request[@"provider"]];
        if (request[@"model"]) [controller.apiConfiguration selectModelID:request[@"model"]];
        if (request[@"subscriptionModel"]) [controller.apiConfiguration selectSubscriptionModelID:request[@"subscriptionModel"]];
        if (request[@"apiKey"]) {
            if (![controller.apiConfiguration saveAPIKey:request[@"apiKey"] error:nil]) { reply(@{@"error": @"The workstation could not save the API key."}); return; }
        }
        if ([request[@"removeAPIKey"] boolValue]) [controller.apiConfiguration removeAPIKeyWithError:nil];
        [controller resetAssistantConversation];
    } else if ([operation isEqualToString:@"settings.models"]) {
        [controller.apiConfiguration refreshModelsWithCompletion:^(NSArray *models, NSError *error) {
            reply(error ? @{@"error": @"The workstation could not refresh its model list."} : @{@"models": models ?: @[]});
        }];
        return;
    } else if ([operation isEqualToString:@"assistant.cancel"]) {
        [controller.assistantClient cancel]; controller.assistantClient = nil;
        controller.assistantRequestGeneration++;
        [controller.assistantView showError:@"Response stopped." settingsAvailable:NO];
    } else if ([operation isEqualToString:@"product.invoke"]) {
        NSString *action = request[@"action"];
        NSString *item = request[@"itemId"] ?: @"";
        if ([action isEqualToString:@"runbook.save"]) [controller.productStore saveRunbookNamed:request[@"name"] ?: @"Playbook" command:request[@"command"] ?: @"" directory:[controller currentAssistantDirectory]];
        else if ([action isEqualToString:@"runbook.update"]) [controller.productStore updateRunbookWithIdentifier:item name:request[@"name"] ?: @"" command:request[@"command"] ?: @"" directory:request[@"directory"] ?: [controller currentAssistantDirectory]];
        else if ([action isEqualToString:@"runbook.delete"]) [controller.productStore deleteRunbookWithIdentifier:item];
        else if ([action isEqualToString:@"runbook.executed"]) [controller.productStore markRunbookExecuted:item];
        else if ([action isEqualToString:@"workspace.save"]) [controller.productStore saveWorkspaceNamed:request[@"name"] ?: @"Workspace" snapshot:request[@"snapshot"] ?: @{}];
        else if ([action isEqualToString:@"workspace.rename"]) [controller.productStore renameWorkspaceWithIdentifier:item name:request[@"name"] ?: @""];
        else if ([action isEqualToString:@"workspace.delete"]) [controller.productStore deleteWorkspaceWithIdentifier:item];
        else if ([action isEqualToString:@"monitor.remove"]) [controller.productStore removeMonitorWithIdentifier:item];
        else { reply(@{@"error": @"This workstation action is unsupported."}); return; }
            [root.sessionServer publish:@{@"type": @"product.changed"}];
    } else if ([operation isEqualToString:@"project.inspect"]) {
        [controller.terminalInspector runCommand:request[@"command"] ?: @"pwd" directory:[controller currentAssistantDirectory] completion:^(NSDictionary *result) { reply(@{@"result": result}); }];
        return;
    } else if ([operation isEqualToString:@"patch.stage"]) {
        NSString *patch = request[@"patch"];
        if (![patch isKindOfClass:NSString.class] || patch.length == 0 || patch.length > 512000) {
            reply(@{@"error": @"The patch is empty or too large."}); return;
        }
        NSString *path = [controller.windowRuntimeDirectory stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"patch"]];
        if (![patch writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]) { reply(@{@"error": @"The workstation could not stage the patch."}); return; }
        [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions: @0600} ofItemAtPath:path error:nil];
        controller.lastAIApplyPatchPath = path;
        NSString *quoted = [controller shellQuotedString:path];
        reply(@{@"command": [NSString stringWithFormat:@"/usr/bin/git apply --check %@ && /usr/bin/git apply %@", quoted, quoted]}); return;
    } else if ([operation isEqualToString:@"patch.revert"]) {
        NSString *path = controller.lastAIApplyPatchPath;
        if (path.length == 0) { reply(@{@"error": @"This workstation has no patch to revert in this session."}); return; }
        NSString *quoted = [controller shellQuotedString:path];
        reply(@{@"command": [NSString stringWithFormat:@"/usr/bin/git apply --reverse --check %@ && /usr/bin/git apply --reverse %@", quoted, quoted]}); return;
    } else if ([operation isEqualToString:@"execution.prepare"]) {
        NSString *command = request[@"command"];
        if (![command isKindOfClass:NSString.class] || command.length == 0 || command.length > 128000) {
            reply(@{@"error": @"The command is empty or too large."}); return;
        }
        for (NSString *old in root.peerApprovals.allKeys)
            if ([root.peerApprovals[old][@"expires"] doubleValue] < NSProcessInfo.processInfo.systemUptime) [root.peerApprovals removeObjectForKey:old];
        if (root.peerApprovals.count >= 256) { reply(@{@"error": @"Too many pending approvals. Wait for existing reviews to expire."}); return; }
        NSString *token = NSUUID.UUID.UUIDString;
        root.peerApprovals[token] = @{@"command": command, @"sessionId": identifier,
            @"principal": request[@"principal"], @"directory": [controller currentAssistantDirectory],
            @"generation": request[@"generation"],
            @"expires": @(NSProcessInfo.processInfo.systemUptime + 120)};
        reply(@{@"approval": token, @"host": NSHost.currentHost.localizedName ?: @"Mac",
            @"directory": [controller currentAssistantDirectory],
            @"permissionMode": [TerminalDBPreferences() stringForKey:@"TerminalDBPermissionMode"] ?: @"ask"}); return;
    } else if ([operation isEqualToString:@"execution.commit"]) {
        NSString *token = request[@"approval"] ?: @"";
        NSDictionary *approval = root.peerApprovals[token];
        [root.peerApprovals removeObjectForKey:token];
        if (!approval || ![approval[@"principal"] isEqual:request[@"principal"]] ||
            ![approval[@"sessionId"] isEqual:identifier] ||
            ![approval[@"generation"] isEqual:request[@"generation"]] ||
            ![approval[@"directory"] isEqual:[controller currentAssistantDirectory]] ||
            [approval[@"expires"] doubleValue] < NSProcessInfo.processInfo.systemUptime || [controller hasForegroundProcessInThisPane]) {
            reply(@{@"error": @"That approval expired, the directory changed, or the terminal is busy. Review the command again."}); return;
        }
        controller.pendingExecutionApproval = @{@"mode": @"native peer approval", @"directory": approval[@"directory"],
            @"host": NSHost.currentHost.localizedName ?: @"Mac", @"approved_at": @(NSDate.date.timeIntervalSince1970)};
        [controller.terminalView pasteString:approval[@"command"]];
        [controller.terminalView sendUserBytes:"\r" length:1];
    } else {
        reply(@{@"error": @"This session operation is unsupported."}); return;
    }
    [controller publishPeerState]; reply(@{@"accepted": @YES});
}

- (void)connectToWorkstation {
    self.sessionClient = [[TDBSessionClient alloc] init];
    self.sessionClient.workstationID = self.peerTarget ?: @"";
    NSString *workstationName = self.peerTarget.length > 0 ? @"Paired Mac" : @"This Mac";
    for (NSDictionary *peer in [self rootController].peerPanel.peerInventory[@"peers"] ?: @[])
        if ([peer[@"id"] isEqual:self.peerTarget]) workstationName = peer[@"name"] ?: workstationName;
    self.sessionClient.workstationName = workstationName;
    [self.claudeStatusBar showEnvironment:@"Reconnecting" host:workstationName detail:@"Connecting to the session service…"];
    [self updateWindowTitle];
    self.ledgerStore = [[TerminalPeerLedgerStore alloc] initWithClient:self.sessionClient];
    self.productStore = [[TerminalPeerProductStore alloc] initWithClient:self.sessionClient];
    self.apiConfiguration = [[TerminalPeerAPIConfiguration alloc] initWithClient:self.sessionClient];
    __weak AppDelegate *weakSelf = self;
    ((TerminalPeerProductStore *)self.productStore).didChange = ^{ [[weakSelf rootController].productWindowController refresh]; };
    self.sessionClient.eventHandler = ^(NSDictionary *event) { [weakSelf acceptPeerEvent:event]; };
    self.terminalView.inputHandler = ^BOOL(NSData *data) { return [weakSelf.sessionClient sendInput:data]; };
    self.terminalView.focusHandler = ^(BOOL focused) {
        if (weakSelf.sessionClient.connected && weakSelf.sessionClient.controlling)
            [weakSelf.sessionClient request:@"terminal.focus" payload:@{@"focused": @(focused)} completion:^(NSDictionary *result) {}];
    };
    self.terminalView.viewer = YES;
    self.terminalView.inputEnabled = NO;
    [self.sessionClient connectWithCompletion:^(NSDictionary *result) {
        AppDelegate *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (result[@"error"]) { [strongSelf showPeerError:result[@"error"]]; return; }
        void (^attached)(NSDictionary *) = ^(NSDictionary *response) {
            if (response[@"error"]) [strongSelf showPeerError:response[@"error"]];
            else if (strongSelf.peerRestoreState && strongSelf.peerAttachSession.length == 0) {
                NSDictionary *snapshot = strongSelf.peerRestoreState; strongSelf.peerRestoreState = nil;
                [strongSelf.sessionClient request:@"workspace.restoreSession" payload:@{@"snapshot": snapshot} completion:^(NSDictionary *restored) {}];
            }
        };
        if (strongSelf.peerAttachSession.length > 0) [strongSelf.sessionClient attach:strongSelf.peerAttachSession completion:attached];
        else {
            strongSelf.sessionClient.privateSessionRequested = strongSelf.peerPrivateRequested;
            [strongSelf.sessionClient create:strongSelf.peerStartDirectory ?: @"" completion:attached];
        }
    }];
}

- (void)showPeerError:(NSString *)message {
    if (message.length == 0) return;
    [self.ledgerBar showConnectionMessage:message];
    NSString *path = self.sessionClient.connected ? self.sessionClient.connectionPath :
        ([message.lowercaseString containsString:@"unreachable"] ? @"Unreachable" : @"Reconnecting");
    [self.claudeStatusBar showEnvironment:path host:self.sessionClient.workstationName detail:message];
    self.peerControlButton.title = @"Reconnect";
    self.peerControlButton.toolTip = message;
}

- (void)acceptPeerEvent:(NSDictionary *)event {
    NSString *type = event[@"type"];
    if ([type isEqualToString:@"attached"] || [type isEqualToString:@"state"]) {
        self.peerState = event[@"state"] ?: @{};
        ((TerminalPeerAPIConfiguration *)self.apiConfiguration).hostConfiguration = self.peerState;
        [self.profileManager replacePeerAccounts:self.peerState[@"accounts"] ?: @[] selected:self.peerState[@"accountId"] ?: @""];
        self.selectedProfile = [self.profileManager profileWithIdentifier:self.peerState[@"accountId"] ?: @""];
        [self.claudeStatusBar applyPeerState:self.peerState];
        ((TerminalPeerLedgerStore *)self.ledgerStore).hostRecordCount = [self.peerState[@"ledgerCount"] unsignedIntegerValue];
        [self.ledgerStore replacePeerRecords:self.peerState[@"records"] ?: @[]];
        [[self rootController].productWindowController refresh];
        self.terminalSessionIdentifier = self.peerState[@"sessionId"] ?: self.terminalSessionIdentifier;
        NSString *host = self.peerTarget.length > 0 ? self.peerState[@"host"] ?: @"Mac" : @"This Mac";
        self.sessionClient.workstationName = host;
        [self updateWindowTitle];
        [self.claudeStatusBar showEnvironment:self.peerTarget.length > 0 ? self.sessionClient.connectionPath : @"LOCAL" host:host detail:self.peerState[@"directory"]];
        [self.claudeStatusBar showDirectory:self.peerState[@"directory"] ?: @"~" model:self.peerState[@"model"]];
        if ([self.peerState[@"command"] length] > 0) [self.ledgerBar beginCommand:self.peerState[@"command"] directory:self.peerState[@"directory"]];
        else if ([self.peerState[@"record"] count] > 0) [self.ledgerBar displayRecord:self.peerState[@"record"]];
        else [self.ledgerBar showReadyInDirectory:self.peerState[@"directory"] ?: @"~"];
        [self.assistantView applyPeerPresentation:self.peerState[@"assistant"] ?: @{}];
        self.assistantMessages = [self.peerState[@"assistant"][@"messages"] mutableCopy] ?: [NSMutableArray array];
        self.assistantResponse = self.peerState[@"assistant"][@"response"] ?: @"";
        self.privateSession = [self.peerState[@"private"] boolValue];
        if (!self.sessionClient.controlling && [self.peerState[@"columns"] integerValue] >= 20 && [self.peerState[@"rows"] integerValue] >= 5) {
            [self.terminalView resizeGridWithColumns:[self.peerState[@"columns"] integerValue] rows:[self.peerState[@"rows"] integerValue]];
        }
        if ([type isEqualToString:@"attached"]) {
            [self.sessionClient request:@"session.snapshot" payload:@{} completion:^(NSDictionary *result) {}];
            if (self.sessionClient.controlling) {
                [self.sessionClient request:@"terminal.resize" payload:@{@"rows": @(self.terminalView.terminalRows), @"columns": @(self.terminalView.terminalColumns)} completion:^(NSDictionary *result) {}];
                [self.sessionClient request:@"terminal.focus" payload:@{@"focused": @(self.window.isKeyWindow)} completion:^(NSDictionary *result) {}];
            }
            void (^action)(void) = self.peerAfterAttach; self.peerAfterAttach = nil;
            if (action) action();
        }
    } else if ([type isEqualToString:@"connection-error"]) {
        [self showPeerError:event[@"detail"] ?: @"The workstation is unreachable."];
    } else if ([type isEqualToString:@"operation-error"]) {
        [self showPeerError:event[@"detail"] ?: @"The workstation could not complete that action."];
    } else if ([type isEqualToString:@"ledger.changed"]) {
        [(TerminalPeerLedgerStore *)self.ledgerStore invalidate];
    } else if ([type isEqualToString:@"product.changed"]) {
        [(TerminalPeerProductStore *)self.productStore invalidate];
    } else if ([type isEqualToString:@"assistant"]) {
        NSMutableDictionary *state = [self.peerState mutableCopy] ?: [NSMutableDictionary dictionary];
        state[@"assistant"] = event[@"state"] ?: @{}; self.peerState = state;
        self.assistantMessages = [state[@"assistant"][@"messages"] mutableCopy] ?: [NSMutableArray array];
        self.assistantResponse = state[@"assistant"][@"response"] ?: @"";
        [self.assistantView applyPeerPresentation:event[@"state"] ?: @{}];
    } else if ([type isEqualToString:@"output"]) {
        NSData *data = [[NSData alloc] initWithBase64EncodedString:event[@"data"] ?: @"" options:0];
        BOOL wasAlternate = self.terminalView.alternateScreenActive;
        if (data) [self consumeTerminalData:data];
        if (self.peerSnapshotNeedsNormalBuffer && wasAlternate && !self.terminalView.alternateScreenActive) {
            self.peerSnapshotNeedsNormalBuffer = NO;
            [self.sessionClient request:@"session.snapshot" payload:@{} completion:^(NSDictionary *result) {}];
        }
    } else if ([type isEqualToString:@"snapshot.begin"]) {
        self.peerSnapshot = [NSMutableData data]; self.peerSnapshotIdentifier = event[@"snapshotId"];
    } else if ([type isEqualToString:@"snapshot.chunk"]) {
        if ([self.peerSnapshotIdentifier isEqual:event[@"snapshotId"]]) {
            NSData *chunk = [[NSData alloc] initWithBase64EncodedString:event[@"data"] ?: @"" options:0];
            if (chunk && self.peerSnapshot.length + chunk.length <= 8 * 1024 * 1024) [self.peerSnapshot appendData:chunk];
            else { self.peerSnapshot = nil; self.peerSnapshotIdentifier = nil; }
        }
    } else if ([type isEqualToString:@"snapshot.end"]) {
        if ([self.peerSnapshotIdentifier isEqual:event[@"snapshotId"]]) {
            [self consumeTerminalData:self.peerSnapshot];
            self.peerSnapshotNeedsNormalBuffer = self.terminalView.alternateScreenActive;
            self.peerSnapshot = nil; self.peerSnapshotIdentifier = nil;
        }
    } else if ([type isEqualToString:@"disconnected"] || [type isEqualToString:@"input-uncertain"]) {
        [self showPeerError:[type isEqualToString:@"input-uncertain"]
            ? event[@"detail"] ?: @"Input delivery is uncertain. Review the terminal before reconnecting; input was not repeated."
            : event[@"detail"] ?: @"Reconnecting to the workstation…"];
    } else if ([type isEqualToString:@"control"]) {
        if (self.sessionClient.controlling && self.sessionClient.sessionID.length > 0 && !self.sessionClient.synchronizing) {
            [self.terminalView useLocalGrid];
            [self updatePTYWindowSize];
            [self.sessionClient request:@"terminal.focus" payload:@{@"focused": @(self.window.isKeyWindow)} completion:^(NSDictionary *result) {}];
            [self.sessionClient request:@"session.snapshot" payload:@{} completion:^(NSDictionary *result) {}];
        }
    } else if ([type isEqualToString:@"ended"]) {
        [self showPeerError:@"This session has ended. Open a new terminal to continue."];
    }
    self.terminalView.inputEnabled = self.sessionClient.connected && self.sessionClient.controlling && !self.sessionClient.synchronizing && !self.sessionClient.snapshotFailed && !self.sessionClient.inputUncertain;
    self.peerControlButton.enabled = !self.sessionClient.ended && !self.sessionClient.synchronizing;
    self.peerControlButton.title = self.sessionClient.ended ? @"Session Ended" : self.sessionClient.snapshotFailed ? @"Reconnect" : self.sessionClient.synchronizing ? @"Synchronizing" : self.sessionClient.inputUncertain ? @"Review Input" : !self.sessionClient.connected ? @"Reconnect" :
        (self.sessionClient.controlling ? @"Controlling" : @"Take Control");
}

- (void)openPeerAccountTab:(NSString *)accountID login:(BOOL)login {
    [self.claudeStatusBar dismissUsagePanel:nil];
    AppDelegate *tab = [[self rootController] newTerminalTabFromWindow:self.window];
    __weak AppDelegate *weakTab = tab;
    tab.peerAfterAttach = ^{
        [weakTab.sessionClient request:@"account.select" payload:@{@"accountId": accountID} completion:^(NSDictionary *result) {
            if (result[@"error"]) return;
            if (login) [weakTab.sessionClient request:@"account.login" payload:@{@"accountId": accountID} completion:^(NSDictionary *response) {}];
            else [weakTab.claudeStatusBar presentUsageWindow];
        }];
    };
}

- (void)takePeerControl:(id)sender {
    (void)sender;
    if (self.sessionClient.ended) return;
    if (self.sessionClient.inputUncertain) {
        NSAlert *alert = [[NSAlert alloc] init]; alert.messageText = @"Review uncertain input";
        alert.informativeText = @"The last input may have reached the workstation. Check the terminal before continuing. TerminalDB will not repeat it.";
        [alert addButtonWithTitle:@"I Have Reviewed It"]; [alert addButtonWithTitle:@"Cancel"];
        if ([alert runModal] == NSAlertFirstButtonReturn) [self.sessionClient acknowledgeUncertainInput];
        return;
    }
    if (!self.sessionClient.connected || self.sessionClient.snapshotFailed) { [self.sessionClient reconnect]; return; }
    [self.sessionClient request:@"control.acquire" payload:@{} completion:^(NSDictionary *result) {}];
}

- (void)requestPeerExecution:(NSString *)command {
    [self.sessionClient request:@"execution.prepare" payload:@{@"command": command ?: @""} completion:^(NSDictionary *result) {
        if (result[@"error"]) { [self showPeerError:result[@"error"]]; return; }
        if ([result[@"permissionMode"] isEqual:@"paste-only"]) { [self.terminalView pasteString:command]; return; }
        void (^commit)(void) = ^{
            [self.sessionClient request:@"execution.commit" payload:@{@"approval": result[@"approval"]} completion:^(NSDictionary *response) {
                if (response[@"error"]) [self showPeerError:response[@"error"]];
            }];
        };
        NSString *environment = [command.lowercaseString containsString:@"production"] || [command.lowercaseString containsString:@"--context prod"] || [command.lowercaseString containsString:@"@prod"] ? @"PRODUCTION" : @"LOCAL";
        TerminalCommandRisk risk = [TerminalPermissionCenter riskForCommand:command environment:environment];
        if ([result[@"permissionMode"] isEqual:@"read-only"] && risk == TerminalCommandRiskReadOnly) { commit(); return; }
        [self.permissionCenter requestPermissionForCommand:command directory:result[@"directory"]
            host:result[@"host"] environment:environment parentWindow:self.window
            completion:^(TerminalCommandPermissionDecision decision) {
                if (decision != TerminalCommandPermissionCancel) commit();
            }];
    }];
}

- (void)endPeerSession:(id)sender {
    (void)sender;
    AppDelegate *active = [[self rootController] activeTerminalController];
    if (!active.sessionClient) return;
    NSAlert *alert = [[NSAlert alloc] init]; alert.messageText = @"End this session?";
    alert.informativeText = [NSString stringWithFormat:@"This stops the shell and its work on %@. Closing a tab instead keeps the work running.", active.sessionClient.workstationName];
    [alert addButtonWithTitle:@"End Session"]; [alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;
    [active.sessionClient request:@"session.end" payload:@{} completion:^(NSDictionary *result) {
        if (result[@"error"]) [active showPeerError:result[@"error"]];
        else [active.window close];
    }];
}

- (void)showPeerPicker:(NSWindow *)hostWindow {
    AppDelegate *root = [self rootController];
    if (!root.peerPanel) root.peerPanel = [[TDBPeerPanel alloc] init];
    NSArray *peers = root.peerPanel.peerInventory[@"peers"] ?: @[];
    NSPopUpButton *workstations = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 420, 28) pullsDown:NO];
    [workstations addItemWithTitle:@"This Mac"];
    for (NSDictionary *peer in peers) [workstations addItemWithTitle:peer[@"name"] ?: @"Mac"];
    AppDelegate *current = [root activeTerminalController];
    for (NSUInteger i = 0; i < peers.count; i++) if ([peers[i][@"id"] isEqual:current.peerTarget]) [workstations selectItemAtIndex:i + 1];
    NSAlert *picker = [[NSAlert alloc] init]; picker.messageText = @"Choose a workstation";
    picker.informativeText = @"Start a new terminal or resume an existing session on this workstation.";
    picker.accessoryView = workstations;
    [picker addButtonWithTitle:@"Continue"]; [picker addButtonWithTitle:@"Cancel"];
    [picker beginSheetModalForWindow:hostWindow completionHandler:^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) return;
        NSString *target = workstations.indexOfSelectedItem == 0 ? @"" : peers[workstations.indexOfSelectedItem - 1][@"id"];
        TDBSessionClient *browser = [[TDBSessionClient alloc] init]; browser.workstationID = target;
        __block BOOL finished = NO;
        NSAlert *progress = [[NSAlert alloc] init]; progress.messageText = @"Connecting to workstation…";
        progress.informativeText = @"Checking direct paths and your paired Macs. Your existing sessions keep running.";
        [progress addButtonWithTitle:@"Cancel"];
        [progress beginSheetModalForWindow:hostWindow completionHandler:^(NSModalResponse response) {
            if (response == NSAlertFirstButtonReturn && !finished) { finished = YES; [browser close]; }
        }];
        void (^failed)(NSString *) = ^(NSString *message) {
            if (finished) return; finished = YES; [browser close];
            [NSApp endSheet:progress.window returnCode:NSAlertSecondButtonReturn];
            NSAlert *error = [[NSAlert alloc] init]; error.messageText = @"The selected workstation is unreachable";
            error.informativeText = message; [error addButtonWithTitle:@"OK"];
            [error beginSheetModalForWindow:hostWindow completionHandler:nil];
        };
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            failed(@"Unreachable. Check that the Mac is awake and logged in, then check its saved address and firewall rule.");
        });
        [browser connectWithCompletion:^(NSDictionary *connected) {
            if (finished) return;
            if (connected[@"error"]) { failed(connected[@"error"]); return; }
            [browser request:@"session.list" payload:@{} completion:^(NSDictionary *result) {
                if (finished) return;
                if (result[@"error"]) { failed(result[@"error"]); return; }
                finished = YES; [NSApp endSheet:progress.window returnCode:NSAlertSecondButtonReturn];
                NSArray *sessions = result[@"sessions"] ?: @[];
                NSPopUpButton *choices = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 460, 28) pullsDown:NO];
                [choices addItemWithTitle:@"New Terminal"];
                for (NSDictionary *session in sessions) [choices addItemWithTitle:[NSString stringWithFormat:@"%@ · %@", session[@"title"], session[@"directory"]]];
                NSAlert *sessionPicker = [[NSAlert alloc] init]; sessionPicker.messageText = @"Open a terminal session";
                sessionPicker.accessoryView = choices;
                [sessionPicker addButtonWithTitle:@"Open"]; [sessionPicker addButtonWithTitle:@"Cancel"];
                [sessionPicker beginSheetModalForWindow:hostWindow completionHandler:^(NSModalResponse selected) {
                    [browser close];
                    if (selected != NSAlertFirstButtonReturn) return;
                    root.peerTarget = target;
                    root.peerAttachSession = choices.indexOfSelectedItem == 0 ? nil : sessions[choices.indexOfSelectedItem - 1][@"sessionId"];
                    AppDelegate *controller = [root createTerminalController];
                    root.peerTarget = nil; root.peerAttachSession = nil;
                    [hostWindow addTabbedWindow:controller.window ordered:NSWindowAbove];
                    hostWindow.tabGroup.selectedWindow = controller.window;
                    [root presentTerminalController:controller];
                }];
            }];
        }];
    }];
}
@end
