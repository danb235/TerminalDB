#import "ClaudeProfile.h"
#import <AppKit/AppKit.h>
#import "TerminalDBTerminal-Swift.h"

#import <CommonCrypto/CommonDigest.h>

NSNotificationName const ClaudeProfilesDidChangeNotification =
    @"ClaudeProfilesDidChangeNotification";

static NSString *const ClaudeProfileStoreErrorDomain =
    @"com.terminaldb.app.ClaudeProfileStore";

static BOOL ClaudeProfileIdentifierIsSafe(NSString *identifier) {
    if (![identifier isKindOfClass:NSString.class] ||
        identifier.length == 0 || identifier.length > 64) {
        return NO;
    }
    NSCharacterSet *allowed = [NSCharacterSet
        characterSetWithCharactersInString:
            @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-"];
    return [identifier rangeOfCharacterFromSet:allowed.invertedSet].location ==
        NSNotFound;
}

@interface ClaudeProfile ()
@property(nonatomic, copy, readwrite) NSString *identifier;
@property(nonatomic, copy, readwrite) NSString *label;
@property(nonatomic, copy, readwrite, nullable) NSString *email;
@property(nonatomic, copy, readwrite, nullable) NSString *subscriptionType;
@property(nonatomic, copy, readwrite) NSString *profileDirectory;
@property(nonatomic, copy, readwrite, nullable) NSString *sharedAccountIdentifier;
@property(nonatomic, readwrite) NSTimeInterval sharedExpiresAt;
@property(nonatomic, readwrite) BOOL knownSignedIn;
@property(nonatomic, readwrite) BOOL catalogOnly;
@property(nonatomic, copy, readwrite) NSArray<NSString *> *catalogLocations;
@property(nonatomic, copy, readwrite) NSString *accountOrganization;
@end

@implementation ClaudeProfile

- (NSString *)catalogIdentifier {
    if (self.sharedAccountIdentifier.length > 0) return self.sharedAccountIdentifier;
    if (self.email.length > 0) return [TDBSharedAccounts identityForEmail:self.email organization:self.accountOrganization ?: @""];
    return self.identifier;
}

- (NSString *)configDirectory {
    return [self.profileDirectory stringByAppendingPathComponent:@"config"];
}

- (NSString *)settingsPath {
    return [self.profileDirectory
        stringByAppendingPathComponent:@"terminaldb-settings.json"];
}

- (NSString *)statusCachePath {
    return [self.profileDirectory
        stringByAppendingPathComponent:@"usage-status.json"];
}

- (NSString *)statusLineCachePath {
    return [self.profileDirectory
        stringByAppendingPathComponent:@"claude-statusline.json"];
}

- (NSString *)usageHistoryPath {
    return [self.profileDirectory
        stringByAppendingPathComponent:@"usage-history.json"];
}

- (NSString *)keychainService {
    NSString *normalized =
        self.configDirectory.precomposedStringWithCanonicalMapping;
    NSData *data = [normalized dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);

    NSMutableString *hash = [NSMutableString stringWithCapacity:8];
    for (NSUInteger index = 0; index < 4; index++) {
        [hash appendFormat:@"%02x", digest[index]];
    }
    return [NSString stringWithFormat:@"Claude Code-credentials-%@", hash];
}

@end

@interface ClaudeProfileManager ()
@property(nonatomic, copy) NSArray<ClaudeProfile *> *profiles;
@property(nonatomic, strong, nullable) ClaudeProfile *lastSelectedProfile;
@property(nonatomic, copy) NSString *profilesRoot;
@property(nonatomic, copy) NSString *storePath;
@end

@implementation ClaudeProfileManager
+ (instancetype)managerForPeerDisplay {
    ClaudeProfileManager *manager = [[self alloc] initForPeerDisplay];
    // No local profile files or credentials are consulted by a remote view.
    manager.profiles = @[];
    return manager;
}
- (instancetype)initForPeerDisplay { return [super init]; }
- (void)replacePeerAccounts:(NSArray<NSDictionary *> *)accounts selected:(NSString *)identifier {
    NSMutableArray *profiles = [NSMutableArray array];
    for (NSDictionary *account in accounts) {
        ClaudeProfile *profile = [[ClaudeProfile alloc] init];
        profile.identifier = account[@"id"] ?: @"";
        profile.label = account[@"label"] ?: @"Claude";
        profile.email = account[@"email"];
        profile.subscriptionType = account[@"plan"];
        profile.sharedAccountIdentifier = account[@"sharedID"];
        profile.sharedExpiresAt = [account[@"sharedExpires"] doubleValue];
        profile.catalogOnly = [account[@"catalogOnly"] boolValue];
        profile.catalogLocations = account[@"locations"] ?: @[];
        profile.accountOrganization = account[@"organization"] ?: @"";
        profile.profileDirectory = @"/__TerminalDBPeerDisplay__";
        [profiles addObject:profile];
    }
    NSMutableSet *seen = [NSMutableSet set];
    for (ClaudeProfile *profile in profiles) [seen addObject:profile.identifier];
    NSMutableArray *localCatalog = [[TDBSharedAccounts catalog] mutableCopy];
    [localCatalog addObjectsFromArray:[TDBSharedAccounts directoryCatalog]];
    for (NSDictionary *item in localCatalog) {
        if ([seen containsObject:item[@"id"]]) continue;
        ClaudeProfile *profile = [[ClaudeProfile alloc] init];
        profile.identifier = item[@"id"]; profile.label = item[@"label"]; profile.email = item[@"email"]; profile.subscriptionType = item[@"plan"];
        profile.catalogLocations = item[@"locations"] ?: @[]; profile.accountOrganization = item[@"organization"] ?: @"";
        profile.catalogOnly = YES; profile.profileDirectory = @"/__TerminalDBPeerDisplay__";
        if (item[@"expires"]) { profile.sharedAccountIdentifier = item[@"id"]; profile.sharedExpiresAt = [item[@"expires"] doubleValue]; }
        [profiles addObject:profile]; [seen addObject:profile.identifier];
    }
    self.profiles = profiles;
    _lastSelectedProfile = [self profileWithIdentifier:identifier];
}

+ (BOOL)runStorageSelfTests {
    NSString *testRoot = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSString stringWithFormat:
            @"terminaldb-profile-manager-%@", NSUUID.UUID.UUIDString]];
    ClaudeProfileManager *manager =
        [self managerForTestingAtRoot:testRoot];
    NSError *error = nil;
    ClaudeProfile *profile = [manager createProfileWithLabel:@"Isolated"
                                                       error:&error];
    NSString *expectedStore =
        [testRoot stringByAppendingPathComponent:@"profiles.json"];
    NSString *expectedDirectory = [[testRoot
        stringByAppendingPathComponent:@"ClaudeProfiles"]
        stringByAppendingPathComponent:profile.identifier ?: @""];
    BOOL isolated = error == nil && profile != nil &&
        [manager.storePath isEqualToString:expectedStore] &&
        [profile.profileDirectory isEqualToString:expectedDirectory] &&
        [NSFileManager.defaultManager fileExistsAtPath:expectedStore];
    [NSFileManager.defaultManager removeItemAtPath:testRoot error:nil];

    return isolated && ClaudeProfileIdentifierIsSafe(
               @"01234567-89ab-cdef-0123-456789abcdef") &&
        ClaudeProfileIdentifierIsSafe(@"work-profile-2") &&
        !ClaudeProfileIdentifierIsSafe(@"../../outside") &&
        !ClaudeProfileIdentifierIsSafe(@"profile/name") &&
        !ClaudeProfileIdentifierIsSafe(@"") &&
        !ClaudeProfileIdentifierIsSafe(
            [@"x" stringByPaddingToLength:65
                               withString:@"x"
                          startingAtIndex:0]);
}

- (instancetype)init {
    NSString *applicationSupport =
        NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                             NSUserDomainMask,
                                             YES).firstObject;
    NSString *root =
        [applicationSupport stringByAppendingPathComponent:@"TerminalDB"];
    return [self initWithStorageRoot:root];
}

+ (instancetype)managerForTestingAtRoot:(NSString *)root {
    NSParameterAssert(root.length > 0);
    return [[self alloc] initWithStorageRoot:root];
}

- (instancetype)initWithStorageRoot:(NSString *)root {
    self = [super init];
    if (self == nil) return nil;

    _profilesRoot =
        [root stringByAppendingPathComponent:@"ClaudeProfiles"];
    _storePath = [root stringByAppendingPathComponent:@"profiles.json"];

    NSFileManager *files = NSFileManager.defaultManager;
    [files createDirectoryAtPath:_profilesRoot
     withIntermediateDirectories:YES
                      attributes:@{NSFilePosixPermissions : @0700}
                           error:nil];
    [files setAttributes:@{NSFilePosixPermissions : @0700}
            ofItemAtPath:root
                   error:nil];
    [files setAttributes:@{NSFilePosixPermissions : @0700}
            ofItemAtPath:_profilesRoot
                   error:nil];

    [self loadProfiles];
    for (ClaudeProfile *profile in _profiles) {
        [self prepareRuntimeFilesForProfile:profile];
    }
    return self;
}

- (void)loadProfiles {
    NSData *data = [NSData dataWithContentsOfFile:self.storePath];
    NSDictionary *store = data.length > 0
        ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil]
        : nil;
    NSArray *savedProfiles =
        [store[@"profiles"] isKindOfClass:NSArray.class]
            ? store[@"profiles"]
            : @[];

    NSMutableArray<ClaudeProfile *> *loaded = [NSMutableArray array];
    NSMutableSet<NSString *> *seenIdentifiers = [NSMutableSet set];
    for (NSDictionary *saved in savedProfiles) {
        if (![saved isKindOfClass:NSDictionary.class]) continue;
        NSString *identifier =
            [saved[@"id"] isKindOfClass:NSString.class] ? saved[@"id"] : nil;
        NSString *label =
            [saved[@"label"] isKindOfClass:NSString.class]
                ? saved[@"label"]
                : nil;
        if (!ClaudeProfileIdentifierIsSafe(identifier) ||
            label.length == 0 ||
            [seenIdentifiers containsObject:identifier]) {
            continue;
        }
        [seenIdentifiers addObject:identifier];

        ClaudeProfile *profile = [[ClaudeProfile alloc] init];
        profile.identifier = identifier;
        profile.label = label;
        profile.email =
            [saved[@"email"] isKindOfClass:NSString.class]
                ? saved[@"email"]
                : nil;
        profile.subscriptionType =
            [saved[@"subscriptionType"] isKindOfClass:NSString.class]
                ? saved[@"subscriptionType"]
                : nil;
        profile.sharedAccountIdentifier = [saved[@"sharedID"] isKindOfClass:NSString.class] ? saved[@"sharedID"] : nil;
        profile.sharedExpiresAt = [saved[@"sharedExpires"] doubleValue];
        profile.knownSignedIn = [saved[@"knownSignedIn"] boolValue];
        profile.catalogOnly = [saved[@"catalogOnly"] boolValue];
        profile.accountOrganization = [saved[@"organization"] isKindOfClass:NSString.class] ? saved[@"organization"] : @"";
        profile.profileDirectory =
            [self.profilesRoot stringByAppendingPathComponent:identifier];
        [loaded addObject:profile];
    }
    self.profiles = loaded;

    NSString *selectedID =
        [store[@"lastSelectedProfileID"] isKindOfClass:NSString.class]
            ? store[@"lastSelectedProfileID"]
            : nil;
    self.lastSelectedProfile =
        selectedID.length > 0 ? [self profileWithIdentifier:selectedID] : nil;
    if (self.lastSelectedProfile == nil) {
        self.lastSelectedProfile = self.profiles.firstObject;
    }
}

- (nullable ClaudeProfile *)profileWithIdentifier:(NSString *)identifier {
    for (ClaudeProfile *profile in self.profiles) {
        if ([profile.identifier isEqualToString:identifier] || [profile.catalogIdentifier isEqualToString:identifier]) return profile;
    }
    return nil;
}

- (void)refreshSharedAccounts {
    if (self.profilesRoot.length == 0) return;
    NSArray *catalog = [TDBSharedAccounts catalog];
    NSDictionary *bindings = [TDBSharedAccounts bindings];
    NSSet *removed = [NSSet setWithArray:[TDBSharedAccounts removedIDs]];
    NSMutableDictionary *items = [NSMutableDictionary dictionary];
    for (NSDictionary *item in [TDBSharedAccounts directoryCatalog]) items[item[@"id"]] = [item mutableCopy];
    for (NSDictionary *item in catalog) {
        NSMutableDictionary *combined = [items[item[@"id"]] mutableCopy] ?: [NSMutableDictionary dictionary];
        [combined addEntriesFromDictionary:item]; combined[@"portable"] = @YES;
        items[item[@"id"]] = combined;
    }
    NSMutableArray *profiles = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    BOOL changed = NO;
    for (ClaudeProfile *profile in self.profiles) {
        NSString *identifier = profile.sharedAccountIdentifier ?: bindings[profile.identifier] ?: profile.catalogIdentifier;
        NSDictionary *item = identifier.length > 0 ? items[identifier] : nil;
        if ([removed containsObject:identifier ?: @""] && profile.sharedAccountIdentifier.length > 0) {
            if ([profile.identifier isEqual:identifier]) { changed = YES; continue; }
            profile.sharedAccountIdentifier = nil; profile.sharedExpiresAt = 0; changed = YES;
        }
        if (item) {
            BOOL portable = [item[@"portable"] boolValue];
            BOOL catalogOnly = !portable && !profile.knownSignedIn;
            if (profile.catalogOnly != catalogOnly || ![profile.catalogLocations isEqual:item[@"locations"] ?: @[]]) changed = YES;
            profile.catalogOnly = catalogOnly; profile.catalogLocations = item[@"locations"] ?: @[];
            if (portable) {
                if (profile.sharedAccountIdentifier.length == 0) [self markProfileReadyForInteractiveClaude:profile];
                if (![profile.sharedAccountIdentifier isEqual:identifier] || profile.sharedExpiresAt != [item[@"expires"] doubleValue]) changed = YES;
                profile.sharedAccountIdentifier = identifier; profile.sharedExpiresAt = [item[@"expires"] doubleValue];
                if (![profile.label isEqual:item[@"label"]] || ![profile.email isEqual:item[@"email"]]) changed = YES;
                profile.label = item[@"label"]; profile.email = item[@"email"]; profile.subscriptionType = item[@"plan"];
                profile.accountOrganization = item[@"organization"] ?: @"";
            }
            [seen addObject:identifier];
        } else if (profile.catalogOnly && [profile.identifier isEqual:profile.catalogIdentifier]) {
            changed = YES; continue;
        }
        [profiles addObject:profile];
    }
    for (NSString *identifier in [[items allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        if ([seen containsObject:identifier] || [removed containsObject:identifier]) continue;
        NSDictionary *item = items[identifier]; BOOL portable = [item[@"portable"] boolValue];
        ClaudeProfile *profile = [[ClaudeProfile alloc] init];
        profile.identifier = identifier; profile.sharedAccountIdentifier = portable ? identifier : nil;
        profile.sharedExpiresAt = [item[@"expires"] doubleValue]; profile.catalogOnly = !portable;
        profile.catalogLocations = item[@"locations"] ?: @[]; profile.accountOrganization = item[@"organization"] ?: @"";
        profile.label = item[@"label"]; profile.email = item[@"email"]; profile.subscriptionType = item[@"plan"];
        profile.profileDirectory = [self.profilesRoot stringByAppendingPathComponent:identifier];
        [self prepareRuntimeFilesForProfile:profile];
        if (portable) [self markProfileReadyForInteractiveClaude:profile];
        [profiles addObject:profile]; changed = YES;
    }
    if (!changed) return;
    self.profiles = profiles;
    if ([self profileWithIdentifier:_lastSelectedProfile.identifier] == nil || _lastSelectedProfile.catalogOnly) {
        _lastSelectedProfile = nil;
        for (ClaudeProfile *profile in self.profiles) if (!profile.catalogOnly && (profile.sharedAccountIdentifier.length == 0 || profile.sharedExpiresAt > NSDate.date.timeIntervalSince1970)) { _lastSelectedProfile = profile; break; }
    }
    [self saveProfiles]; [self notifyProfilesChanged];
}

- (void)recordSignInState:(BOOL)signedIn forProfile:(ClaudeProfile *)profile {
    if (profile.sharedAccountIdentifier.length > 0 || profile.catalogOnly || profile.knownSignedIn == signedIn) return;
    profile.knownSignedIn = signedIn; [self saveProfiles];
}

- (NSArray<NSDictionary *> *)localAccountCatalog {
    NSMutableArray *items = [NSMutableArray array];
    for (ClaudeProfile *profile in self.profiles) {
        if (!profile.knownSignedIn || profile.catalogOnly || profile.sharedAccountIdentifier.length > 0 || profile.email.length == 0) continue;
        [items addObject:@{@"id": profile.catalogIdentifier, @"label": profile.label, @"email": profile.email,
            @"organization": profile.accountOrganization ?: @"", @"plan": profile.subscriptionType ?: @""}];
    }
    return [items sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [a[@"id"] compare:b[@"id"]]; }];
}

- (nullable ClaudeProfile *)createProfileWithLabel:(NSString *)label
                                             error:(NSError **)error {
    NSString *trimmed =
        [label stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:ClaudeProfileStoreErrorDomain
                                         code:1
                                     userInfo:@{
                NSLocalizedDescriptionKey : @"Enter a name for this account.",
            }];
        }
        return nil;
    }
    ClaudeProfile *profile = [[ClaudeProfile alloc] init];
    profile.identifier = NSUUID.UUID.UUIDString.lowercaseString;
    profile.label = trimmed;
    profile.profileDirectory =
        [self.profilesRoot stringByAppendingPathComponent:profile.identifier];

    NSFileManager *files = NSFileManager.defaultManager;
    BOOL created =
        [files createDirectoryAtPath:profile.configDirectory
         withIntermediateDirectories:YES
                          attributes:@{NSFilePosixPermissions : @0700}
                               error:error];
    if (!created) return nil;
    [files setAttributes:@{NSFilePosixPermissions : @0700}
            ofItemAtPath:profile.profileDirectory
                   error:nil];
    [files setAttributes:@{NSFilePosixPermissions : @0700}
            ofItemAtPath:profile.configDirectory
                   error:nil];

    self.profiles = [self.profiles arrayByAddingObject:profile];
    self.lastSelectedProfile = profile;
    [self prepareRuntimeFilesForProfile:profile];
    [self saveProfiles];
    [self notifyProfilesChanged];
    return profile;
}

- (BOOL)removeProfile:(ClaudeProfile *)profile error:(NSError **)error {
    ClaudeProfile *managed =
        [self profileWithIdentifier:profile.identifier];
    if (managed == nil) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:ClaudeProfileStoreErrorDomain
                                         code:3
                                     userInfo:@{
                NSLocalizedDescriptionKey :
                    @"This Claude Code account is no longer in TerminalDB.",
            }];
        }
        return NO;
    }

    NSFileManager *files = NSFileManager.defaultManager;
    if ([files fileExistsAtPath:managed.profileDirectory] &&
        ![files removeItemAtPath:managed.profileDirectory error:error]) {
        return NO;
    }

    NSMutableArray<ClaudeProfile *> *remaining =
        [self.profiles mutableCopy];
    [remaining removeObject:managed];
    self.profiles = remaining;
    if ([self.lastSelectedProfile.identifier
            isEqualToString:managed.identifier]) {
        self.lastSelectedProfile = self.profiles.firstObject;
    }
    [self saveProfiles];
    [self notifyProfilesChanged];

    // Claude Code stores the credential separately from its configuration
    // directory. Remove that now-unused item without ever reading its value.
    NSTask *keychainCleanup = [[NSTask alloc] init];
    keychainCleanup.executableURL =
        [NSURL fileURLWithPath:@"/usr/bin/security"];
    keychainCleanup.arguments = @[
        @"delete-generic-password",
        @"-s",
        managed.keychainService,
    ];
    keychainCleanup.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    keychainCleanup.standardError = [NSFileHandle fileHandleWithNullDevice];
    if ([keychainCleanup launchAndReturnError:nil]) {
        [keychainCleanup waitUntilExit];
    }
    return YES;
}

- (void)setLastSelectedProfile:(ClaudeProfile *)profile {
    _lastSelectedProfile = profile;
    [self saveProfiles];
}

- (void)updateProfile:(ClaudeProfile *)profile
                email:(NSString *)email
     subscriptionType:(NSString *)subscriptionType {
    BOOL changed = !profile.knownSignedIn || ![profile.email ?: @"" isEqualToString:email ?: @""] ||
        ![profile.subscriptionType ?: @""
            isEqualToString:subscriptionType ?: @""];
    profile.knownSignedIn = YES;
    profile.email = email;
    profile.subscriptionType = subscriptionType;
    id parsedConfiguration = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[profile.configDirectory stringByAppendingPathComponent:@".claude.json"]] ?: [NSData data] options:0 error:nil];
    NSDictionary *configuration = [parsedConfiguration isKindOfClass:NSDictionary.class] ? parsedConfiguration : @{};
    NSDictionary *oauth = [configuration[@"oauthAccount"] isKindOfClass:NSDictionary.class] ? configuration[@"oauthAccount"] : @{};
    NSString *organization = [oauth[@"organizationUuid"] isKindOfClass:NSString.class] ? oauth[@"organizationUuid"] : nil;
    if (organization.length > 0 && ![profile.accountOrganization isEqual:organization]) { profile.accountOrganization = organization; changed = YES; }
    if (!changed) return;
    [self saveProfiles];
    [self notifyProfilesChanged];
}

- (void)prepareRuntimeFilesForProfile:(ClaudeProfile *)profile {
    NSFileManager *files = NSFileManager.defaultManager;
    [files createDirectoryAtPath:profile.configDirectory
     withIntermediateDirectories:YES
                      attributes:@{NSFilePosixPermissions : @0700}
                           error:nil];

    NSString *bridge = [NSBundle.mainBundle
        pathForResource:@"claude-status-bridge"
                 ofType:@"sh"
            inDirectory:@"Scripts"];
    NSString *stateBridge = [NSBundle.mainBundle
        pathForResource:@"claude-tab-state"
                 ofType:@"sh"
            inDirectory:@"Scripts"];
    if (bridge.length == 0 || stateBridge.length == 0) return;
    NSString *escaped =
        [bridge stringByReplacingOccurrencesOfString:@"'"
                                          withString:@"'\\''"];
    NSString *escapedStateBridge =
        [stateBridge stringByReplacingOccurrencesOfString:@"'"
                                               withString:@"'\\''"];
    NSDictionary *(^stateHook)(NSString *) =
        ^NSDictionary *(NSString *state) {
            return @{
                @"hooks" : @[
                    @{
                        @"type" : @"command",
                        @"command" : [NSString stringWithFormat:
                            @"'%@' %@", escapedStateBridge, state],
                    },
                ],
            };
        };
    NSDictionary *settings = @{
        @"statusLine" : @{
            @"type" : @"command",
            @"command" : [NSString stringWithFormat:@"'%@'", escaped],
            @"refreshInterval" : @5,
        },
        @"hooks" : @{
            @"SessionStart" : @[stateHook(@"ready")],
            @"UserPromptSubmit" : @[stateHook(@"working")],
            @"PreToolUse" : @[stateHook(@"working")],
            @"PermissionRequest" : @[stateHook(@"attention")],
            @"Notification" : @[stateHook(@"attention")],
            @"Stop" : @[stateHook(@"ready")],
        },
    };
    NSData *settingsData =
        [NSJSONSerialization dataWithJSONObject:settings
                                         options:NSJSONWritingPrettyPrinted
                                           error:nil];
    [settingsData writeToFile:profile.settingsPath atomically:YES];
    [files setAttributes:@{NSFilePosixPermissions : @0600}
            ofItemAtPath:profile.settingsPath
                   error:nil];
}

- (void)markProfileReadyForInteractiveClaude:(ClaudeProfile *)profile {
    NSString *statePath =
        [profile.configDirectory stringByAppendingPathComponent:@".claude.json"];
    NSData *existingData = [NSData dataWithContentsOfFile:statePath];
    NSDictionary *existing = existingData.length > 0
        ? [NSJSONSerialization JSONObjectWithData:existingData
                                           options:0
                                             error:nil]
        : nil;
    NSMutableDictionary *state =
        [existing isKindOfClass:NSDictionary.class]
            ? [existing mutableCopy]
            : [NSMutableDictionary dictionary];

    if ([state[@"hasCompletedOnboarding"] boolValue]) return;

    state[@"hasCompletedOnboarding"] = @YES;
    NSData *updated =
        [NSJSONSerialization dataWithJSONObject:state
                                         options:NSJSONWritingPrettyPrinted
                                           error:nil];
    if ([updated writeToFile:statePath atomically:YES]) {
        [NSFileManager.defaultManager
            setAttributes:@{NSFilePosixPermissions : @0600}
            ofItemAtPath:statePath
            error:nil];
    }
}

- (void)saveProfiles {
    NSMutableArray *savedProfiles = [NSMutableArray array];
    for (ClaudeProfile *profile in self.profiles) {
        NSMutableDictionary *saved = [@{
            @"id" : profile.identifier,
            @"label" : profile.label,
        } mutableCopy];
        if (profile.email.length > 0) saved[@"email"] = profile.email;
        if (profile.subscriptionType.length > 0) {
            saved[@"subscriptionType"] = profile.subscriptionType;
        }
        saved[@"knownSignedIn"] = @(profile.knownSignedIn);
        saved[@"catalogOnly"] = @(profile.catalogOnly);
        saved[@"organization"] = profile.accountOrganization ?: @"";
        if (profile.sharedAccountIdentifier.length > 0) {
            saved[@"sharedID"] = profile.sharedAccountIdentifier;
            saved[@"sharedExpires"] = @(profile.sharedExpiresAt);
        }
        [savedProfiles addObject:saved];
    }

    NSMutableDictionary *store = [@{
        @"version" : @1,
        @"profiles" : savedProfiles,
    } mutableCopy];
    if (self.lastSelectedProfile.identifier.length > 0) {
        store[@"lastSelectedProfileID"] =
            self.lastSelectedProfile.identifier;
    }
    NSData *data =
        [NSJSONSerialization dataWithJSONObject:store
                                         options:NSJSONWritingPrettyPrinted
                                           error:nil];
    [data writeToFile:self.storePath atomically:YES];
    [NSFileManager.defaultManager
        setAttributes:@{NSFilePosixPermissions : @0600}
        ofItemAtPath:self.storePath
        error:nil];
}

- (void)notifyProfilesChanged {
    [NSNotificationCenter.defaultCenter
        postNotificationName:ClaudeProfilesDidChangeNotification
                      object:self];
}

@end
