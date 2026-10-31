#import "TerminalPeerStores.h"

@interface TerminalPeerLedgerStore ()
@property(nonatomic, strong) TDBSessionClient *client;
@property(nonatomic, copy) NSString *loadedQuery;
@property(nonatomic) NSUInteger queryGeneration;
@property(nonatomic, strong) NSDate *queryLoadedAt;
@end
@implementation TerminalPeerLedgerStore
- (instancetype)initWithClient:(TDBSessionClient *)client {
    self = [super initInMemory]; if (self) _client = client; return self;
}
- (void)invalidate {
    self.loadedQuery = nil; self.queryLoadedAt = nil; self.queryGeneration++;
    [NSNotificationCenter.defaultCenter postNotificationName:TerminalLedgerDidChangeNotification object:self];
}
- (void)replacePeerRecords:(NSArray *)records {
    if (records.count == 0) { [super replacePeerRecords:@[]]; return; }
    NSMutableDictionary *byID = [NSMutableDictionary dictionary];
    for (NSDictionary *item in self.records) if (item[@"id"]) byID[item[@"id"]] = item;
    for (NSDictionary *item in records) {
        NSString *identifier = item[@"id"]; if (!identifier) continue;
        NSMutableDictionary *merged = [item mutableCopy];
        NSString *previous = byID[identifier][@"output"];
        if (previous.length > [item[@"output"] length]) merged[@"output"] = previous;
        byID[identifier] = merged;
    }
    NSArray *merged = [byID.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"timestamp"] ?: @0 compare:a[@"timestamp"] ?: @0];
    }];
    if (self.hostRecordCount > 0 && merged.count > self.hostRecordCount) merged = [merged subarrayWithRange:NSMakeRange(0, self.hostRecordCount)];
    [super replacePeerRecords:merged];
}
- (NSArray *)recordsMatching:(NSString *)query { return [self recordsMatching:query filters:nil]; }
- (NSArray *)recordsMatching:(NSString *)query filters:(NSDictionary *)filters {
    NSString *key = [NSString stringWithFormat:@"%@:%@", query ?: @"", filters ?: @{}];
    if ((! [self.loadedQuery isEqual:key] || (self.queryLoadedAt && -self.queryLoadedAt.timeIntervalSinceNow > 3)) && self.client.connected) {
        self.loadedQuery = key; self.queryLoadedAt = nil;
        NSUInteger generation = ++self.queryGeneration;
        [self loadPageForQuery:query ?: @"" filters:filters ?: @{} offset:0
                      records:[NSMutableArray array] generation:generation];
    }
    return [super recordsMatching:query filters:filters];
}
- (void)loadPageForQuery:(NSString *)query filters:(NSDictionary *)filters offset:(NSUInteger)offset
                 records:(NSMutableArray *)records generation:(NSUInteger)generation {
    [self.client request:@"ledger.query" payload:@{@"query": query, @"filters": filters, @"offset": @(offset)} completion:^(NSDictionary *result) {
        if (generation != self.queryGeneration || result[@"error"]) return;
        NSArray *page = result[@"records"] ?: @[];
        [records addObjectsFromArray:page];
        [self replacePeerRecords:records];
        if (page.count > 0 && records.count < [result[@"total"] unsignedIntegerValue] && records.count < 50000) {
            [self loadPageForQuery:query filters:filters offset:offset + page.count records:records generation:generation];
        } else self.queryLoadedAt = NSDate.date;
    }];
}
- (void)toggleBookmarkForRecord:(NSString *)identifier {
    [self.client request:@"ledger.bookmark" payload:@{@"recordId": identifier} completion:^(NSDictionary *result) {
        if (!result[@"error"]) [self invalidate];
    }];
}
- (void)clearHistory {
    [self.client request:@"ledger.clear" payload:@{} completion:^(NSDictionary *result) {
        if (!result[@"error"]) { self.loadedQuery = nil; [super replacePeerRecords:@[]]; }
    }];
}
@end

@interface TerminalPeerProductStore ()
@property(nonatomic, strong) TDBSessionClient *client;
@property(nonatomic, strong) NSMutableSet *loading;
@property(nonatomic, strong) NSMutableDictionary *lastLoaded;
@property(nonatomic, strong) NSMutableDictionary *collections;
@end
@implementation TerminalPeerProductStore
- (instancetype)initWithClient:(TDBSessionClient *)client {
    self = [super initInMemory];
    if (self) { _client = client; _loading = [NSMutableSet set]; _lastLoaded = [NSMutableDictionary dictionary]; _collections = [NSMutableDictionary dictionary]; }
    return self;
}
- (void)invalidate { [self.lastLoaded removeAllObjects]; if (self.didChange) self.didChange(); }
- (void)load:(NSString *)kind {
    if (!self.client.connected || [self.loading containsObject:kind] ||
        NSProcessInfo.processInfo.systemUptime - [self.lastLoaded[kind] doubleValue] < 2) return;
    [self.loading addObject:kind];
    [self load:kind offset:0 accumulated:[NSMutableArray array]];
}
- (void)load:(NSString *)kind offset:(NSUInteger)offset accumulated:(NSMutableArray *)items {
    [self.client request:@"product.list" payload:@{@"kind": kind, @"offset": @(offset)} completion:^(NSDictionary *result) {
        if (result[@"error"]) { [self.loading removeObject:kind]; return; }
        NSArray *page = result[@"items"] ?: @[];
        [items addObjectsFromArray:page];
        if (page.count > 0 && offset + page.count < [result[@"total"] unsignedIntegerValue] && items.count < 50000) {
            [self load:kind offset:offset + page.count accumulated:items]; return;
        }
        [self.loading removeObject:kind]; self.lastLoaded[kind] = @(NSProcessInfo.processInfo.systemUptime);
        self.collections[kind] = items;
        [super replacePeerState:self.collections];
        if (self.didChange) self.didChange();
    }];
}
- (NSArray *)runbooks { [self load:@"runbooks"]; return [super runbooks]; }
- (NSArray *)workspaces { [self load:@"workspaces"]; return [super workspaces]; }
- (NSArray *)monitors { [self load:@"monitors"]; return [super monitors]; }
- (void)invoke:(NSString *)action fields:(NSDictionary *)fields {
    NSMutableDictionary *payload = [fields mutableCopy]; payload[@"action"] = action;
    [self.client request:@"product.invoke" payload:payload completion:^(NSDictionary *result) {
        if (!result[@"error"]) [self invalidate];
        if (self.operationFeedback) {
            NSString *host = self.client.workstationName ?: @"the workstation";
            NSString *message = result[@"error"]
                ? [NSString stringWithFormat:@"Couldn’t save changes on %@. %@", host, result[@"error"]]
                : [NSString stringWithFormat:@"Changes saved on %@.", host];
            self.operationFeedback(message, result[@"error"] != nil);
        }
    }];
}
- (NSDictionary *)saveRunbookNamed:(NSString *)name command:(NSString *)command directory:(NSString *)directory {
    [self invoke:@"runbook.save" fields:@{@"name": name, @"command": command, @"directory": directory}]; return @{};
}
- (void)updateRunbookWithIdentifier:(NSString *)identifier name:(NSString *)name command:(NSString *)command directory:(NSString *)directory {
    [self invoke:@"runbook.update" fields:@{@"itemId": identifier, @"name": name, @"command": command, @"directory": directory}];
}
- (void)markRunbookExecuted:(NSString *)identifier { [self invoke:@"runbook.executed" fields:@{@"itemId": identifier}]; }
- (void)deleteRunbookWithIdentifier:(NSString *)identifier { [self invoke:@"runbook.delete" fields:@{@"itemId": identifier}]; }
- (NSDictionary *)saveWorkspaceNamed:(NSString *)name snapshot:(NSDictionary *)snapshot {
    [self invoke:@"workspace.save" fields:@{@"name": name, @"snapshot": snapshot}]; return @{};
}
- (NSDictionary *)saveWorkspaceNamed:(NSString *)name directory:(NSString *)directory accountLabel:(NSString *)accountLabel chatTitle:(NSString *)chatTitle {
    return [self saveWorkspaceNamed:name snapshot:@{@"directory": directory, @"account": accountLabel ?: @"", @"chat": chatTitle ?: @""}];
}
- (void)renameWorkspaceWithIdentifier:(NSString *)identifier name:(NSString *)name {
    [self invoke:@"workspace.rename" fields:@{@"itemId": identifier, @"name": name}];
}
- (void)deleteWorkspaceWithIdentifier:(NSString *)identifier { [self invoke:@"workspace.delete" fields:@{@"itemId": identifier}]; }
- (void)removeMonitorWithIdentifier:(NSString *)identifier { [self invoke:@"monitor.remove" fields:@{@"itemId": identifier}]; }
@end

@interface TerminalPeerAPIConfiguration ()
@property(nonatomic, strong) TDBSessionClient *client;
@end
@implementation TerminalPeerAPIConfiguration
- (instancetype)initWithClient:(TDBSessionClient *)client {
    self = [super init]; if (self) { _client = client; _hostConfiguration = @{}; } return self;
}
- (BOOL)hasAPIKey { return [self.hostConfiguration[@"hasAPIKey"] boolValue]; }
- (NSString *)apiKey { return nil; }
- (NSArray *)models { return self.hostConfiguration[@"models"] ?: @[]; }
- (NSString *)chatProvider { return self.hostConfiguration[@"provider"] ?: ClaudeAIProviderSubscription; }
- (NSString *)selectedModelID { return self.hostConfiguration[@"apiModel"]; }
- (NSString *)subscriptionModelID { return self.hostConfiguration[@"subscriptionModel"] ?: @"default"; }
- (void)update:(NSDictionary *)fields {
    [self.client request:@"settings.update" payload:fields completion:^(NSDictionary *result) {
        if (result[@"error"]) {
            NSAlert *alert = [[NSAlert alloc] init]; alert.messageText = @"Workstation settings";
            alert.informativeText = result[@"error"]; [alert runModal];
        }
    }];
}
- (void)storeAPIKey:(NSString *)key completion:(void (^)(NSError *))completion {
    [self.client request:@"settings.update" payload:@{@"apiKey": key} completion:^(NSDictionary *result) {
        NSError *error = result[@"error"] ? [NSError errorWithDomain:@"com.terminaldb.peer" code:1 userInfo:@{NSLocalizedDescriptionKey: result[@"error"]}] : nil;
        completion(error);
    }];
}
- (void)deleteAPIKeyWithCompletion:(void (^)(NSError *))completion {
    [self.client request:@"settings.update" payload:@{@"removeAPIKey": @YES} completion:^(NSDictionary *result) {
        NSError *error = result[@"error"] ? [NSError errorWithDomain:@"com.terminaldb.peer" code:1 userInfo:@{NSLocalizedDescriptionKey: result[@"error"]}] : nil;
        completion(error);
    }];
}
- (BOOL)saveAPIKey:(NSString *)key error:(NSError **)error { [self update:@{@"apiKey": key}]; return YES; }
- (BOOL)removeAPIKeyWithError:(NSError **)error { [self update:@{@"removeAPIKey": @YES}]; return YES; }
- (void)selectChatProvider:(NSString *)provider { [self update:@{@"provider": provider}]; }
- (void)selectModelID:(NSString *)model { [self update:@{@"model": model}]; }
- (void)selectSubscriptionModelID:(NSString *)model { [self update:@{@"subscriptionModel": model}]; }
- (void)refreshModelsWithCompletion:(void (^)(NSArray<NSDictionary *> *, NSError * _Nullable))completion {
    [self.client request:@"settings.models" payload:@{} completion:^(NSDictionary *result) {
        NSError *error = result[@"error"] ? [NSError errorWithDomain:@"com.terminaldb.peer" code:1 userInfo:@{NSLocalizedDescriptionKey: result[@"error"]}] : nil;
        if (!error) {
            NSMutableDictionary *state = [self.hostConfiguration mutableCopy]; state[@"models"] = result[@"models"] ?: @[];
            self.hostConfiguration = state;
        }
        completion(result[@"models"] ?: @[], error);
    }];
}
@end
