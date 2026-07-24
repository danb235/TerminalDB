#import "ClaudeProfile.h"

#import <CommonCrypto/CommonDigest.h>

NSNotificationName const ClaudeProfilesDidChangeNotification =
    @"ClaudeProfilesDidChangeNotification";

static NSString *const ClaudeProfileStoreErrorDomain =
    @"com.terminaldb.app.ClaudeProfileStore";

@interface ClaudeProfile ()
@property(nonatomic, copy, readwrite) NSString *identifier;
@property(nonatomic, copy, readwrite) NSString *label;
@property(nonatomic, copy, readwrite, nullable) NSString *email;
@property(nonatomic, copy, readwrite, nullable) NSString *subscriptionType;
@property(nonatomic, copy, readwrite) NSString *profileDirectory;
@end

@implementation ClaudeProfile

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

- (instancetype)init {
    self = [super init];
    if (self == nil) return nil;

    NSString *applicationSupport =
        NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                             NSUserDomainMask,
                                             YES).firstObject;
    NSString *root =
        [applicationSupport stringByAppendingPathComponent:@"TerminalDB"];
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
    for (NSDictionary *saved in savedProfiles) {
        if (![saved isKindOfClass:NSDictionary.class]) continue;
        NSString *identifier =
            [saved[@"id"] isKindOfClass:NSString.class] ? saved[@"id"] : nil;
        NSString *label =
            [saved[@"label"] isKindOfClass:NSString.class]
                ? saved[@"label"]
                : nil;
        if (identifier.length == 0 || label.length == 0) continue;

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
        if ([profile.identifier isEqualToString:identifier]) return profile;
    }
    return nil;
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
    BOOL changed = ![profile.email ?: @"" isEqualToString:email ?: @""] ||
        ![profile.subscriptionType ?: @""
            isEqualToString:subscriptionType ?: @""];
    profile.email = email;
    profile.subscriptionType = subscriptionType;
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
