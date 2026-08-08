#import "TerminalUpdater.h"

#import <CommonCrypto/CommonDigest.h>

static NSString *const TerminalUpdaterLastCheckKey =
    @"TerminalDBUpdaterLastCheckAt";
static NSTimeInterval const TerminalUpdaterCheckInterval = 24.0 * 60.0 * 60.0;

@implementation TerminalUpdateRelease
@end

@interface TerminalUpdater ()
@property(nonatomic, copy) NSString *repository;
@property(nonatomic, strong, readwrite, nullable)
    TerminalUpdateRelease *availableRelease;
@property(nonatomic, readwrite, getter=isChecking) BOOL checking;
@property(nonatomic, readwrite, getter=isDownloading) BOOL downloading;
@property(nonatomic, strong, nullable) NSURL *activeUpdateDirectory;
@end

@implementation TerminalUpdater

- (instancetype)initWithRepository:(NSString *)repository {
    self = [super init];
    if (self != nil) {
        _repository = [repository copy];
    }
    return self;
}

- (NSString *)currentVersion {
    NSString *version = [NSBundle.mainBundle
        objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    return [version isKindOfClass:NSString.class] && version.length > 0
        ? version : @"0";
}

- (void)notifyStatusChanged {
    if (self.statusDidChange != nil) self.statusDidChange();
}

- (void)checkOnLaunchIfDue {
    NSTimeInterval lastCheck =
        [NSUserDefaults.standardUserDefaults
            doubleForKey:TerminalUpdaterLastCheckKey];
    if ([NSDate date].timeIntervalSince1970 - lastCheck <
            TerminalUpdaterCheckInterval) {
        return;
    }
    [self checkForUpdatesFromWindow:nil force:NO];
}

- (void)checkForUpdatesFromWindow:(NSWindow *)window {
    if (self.availableRelease != nil) {
        [self presentAvailableUpdateFromWindow:window];
        return;
    }
    [self checkForUpdatesFromWindow:window force:YES];
}

- (void)checkForUpdatesFromWindow:(NSWindow *)window force:(BOOL)force {
    if (self.checking || self.downloading) return;
    self.checking = YES;
    [self notifyStatusChanged];
    [NSUserDefaults.standardUserDefaults
        setDouble:[NSDate date].timeIntervalSince1970
           forKey:TerminalUpdaterLastCheckKey];

    NSString *escapedRepository = [self.repository
        stringByAddingPercentEncodingWithAllowedCharacters:
            NSCharacterSet.URLPathAllowedCharacterSet];
    NSString *urlString = [NSString stringWithFormat:
        @"https://api.github.com/repos/%@/releases?per_page=20",
        escapedRepository];
    NSMutableURLRequest *request = [NSMutableURLRequest
        requestWithURL:[NSURL URLWithString:urlString]];
    request.timeoutInterval = 15.0;
    [request setValue:@"application/vnd.github+json"
   forHTTPHeaderField:@"Accept"];
    [request setValue:@"TerminalDB updater"
   forHTTPHeaderField:@"User-Agent"];

    __weak TerminalUpdater *weakSelf = self;
    NSURLSessionDataTask *task =
        [NSURLSession.sharedSession
            dataTaskWithRequest:request
              completionHandler:^(NSData *data, NSURLResponse *response,
                                  NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            TerminalUpdater *strongSelf = weakSelf;
            if (strongSelf == nil) return;
            strongSelf.checking = NO;
            NSInteger status =
                [response isKindOfClass:NSHTTPURLResponse.class]
                    ? ((NSHTTPURLResponse *)response).statusCode : 0;
            NSError *jsonError = nil;
            id json = data.length > 0
                ? [NSJSONSerialization JSONObjectWithData:data
                                                  options:0
                                                    error:&jsonError]
                : nil;
            TerminalUpdateRelease *release =
                error == nil && status == 200 && jsonError == nil
                    ? [TerminalUpdater bestReleaseFromJSONArray:json]
                    : nil;
            if (release != nil &&
                [TerminalUpdater isVersion:release.version
                                  newerThan:strongSelf.currentVersion]) {
                strongSelf.availableRelease = release;
                [strongSelf notifyStatusChanged];
                if (force) {
                    [strongSelf presentAvailableUpdateFromWindow:window];
                }
                return;
            }
            [strongSelf notifyStatusChanged];
            if (!force) return;
            if (error != nil || status != 200 || jsonError != nil) {
                NSString *message = error.localizedDescription;
                if (message.length == 0 && jsonError != nil) {
                    message = jsonError.localizedDescription;
                }
                if (message.length == 0) {
                    message = status > 0
                        ? [NSString stringWithFormat:
                            @"GitHub returned status %ld.", (long)status]
                        : @"The release feed did not respond.";
                }
                [strongSelf showAlertWithTitle:
                    @"Could not check for updates"
                    message:message window:window];
            } else {
                [strongSelf showAlertWithTitle:@"TerminalDB is up to date"
                    message:[NSString stringWithFormat:
                        @"You are using version %@.",
                        strongSelf.currentVersion]
                    window:window];
            }
        });
    }];
    [task resume];
}

- (void)presentAvailableUpdateFromWindow:(NSWindow *)window {
    TerminalUpdateRelease *release = self.availableRelease;
    if (release == nil || self.downloading) return;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleInformational;
    alert.messageText = [NSString stringWithFormat:
        @"TerminalDB %@ is available", release.version];
    NSString *notes = [release.notes
        stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (notes.length > 1400) {
        notes = [[notes substringToIndex:1400]
            stringByAppendingString:@"\n\nMore details are available on GitHub."];
    }
    alert.informativeText = notes.length > 0
        ? [NSString stringWithFormat:
            @"You are using %@.\n\n%@", self.currentVersion, notes]
        : [NSString stringWithFormat:
            @"You are using %@. Download, verify, install, and relaunch now?",
            self.currentVersion];
    [alert addButtonWithTitle:@"Install and Relaunch"];
    [alert addButtonWithTitle:@"Later"];
    [alert addButtonWithTitle:@"View Release"];
    void (^handle)(NSModalResponse) = ^(NSModalResponse response) {
        if (response == NSAlertFirstButtonReturn) {
            [self installRelease:release fromWindow:window];
        } else if (response == NSAlertThirdButtonReturn) {
            [NSWorkspace.sharedWorkspace openURL:release.releaseURL];
        }
    };
    if (window != nil && window.visible) {
        [alert beginSheetModalForWindow:window completionHandler:handle];
    } else {
        handle([alert runModal]);
    }
}

- (void)installRelease:(TerminalUpdateRelease *)release
            fromWindow:(NSWindow *)window {
    if (self.downloading) return;
    self.downloading = YES;
    [self notifyStatusChanged];

    NSString *workingPath = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSString stringWithFormat:
            @"terminaldb-update-%@", NSUUID.UUID.UUIDString]];
    NSError *directoryError = nil;
    [NSFileManager.defaultManager
        createDirectoryAtPath:workingPath
        withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions : @0700}
        error:&directoryError];
    if (directoryError != nil) {
        [self finishInstallWithError:directoryError window:window];
        return;
    }
    self.activeUpdateDirectory = [NSURL fileURLWithPath:workingPath];

    NSURL *zipPath = [NSURL fileURLWithPath:
        [workingPath stringByAppendingPathComponent:@"update.zip"]];
    __weak TerminalUpdater *weakSelf = self;
    NSURLSessionDownloadTask *zipTask =
        [NSURLSession.sharedSession
            downloadTaskWithURL:release.zipURL
             completionHandler:^(NSURL *location, NSURLResponse *response,
                                 NSError *error) {
        TerminalUpdater *strongSelf = weakSelf;
        if (strongSelf == nil) return;
        NSInteger status =
            [response isKindOfClass:NSHTTPURLResponse.class]
                ? ((NSHTTPURLResponse *)response).statusCode : 0;
        if (error != nil || location == nil || status != 200) {
            NSError *downloadError = error ?: [NSError
                errorWithDomain:@"TerminalDBUpdater"
                           code:status
                       userInfo:@{NSLocalizedDescriptionKey:
                           @"The update archive could not be downloaded."}];
            dispatch_async(dispatch_get_main_queue(), ^{
                [strongSelf finishInstallWithError:downloadError window:window];
            });
            return;
        }
        NSError *moveError = nil;
        [NSFileManager.defaultManager moveItemAtURL:location
                                              toURL:zipPath
                                              error:&moveError];
        if (moveError != nil) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [strongSelf finishInstallWithError:moveError window:window];
            });
            return;
        }

        NSURLSessionDataTask *checksumTask =
            [NSURLSession.sharedSession
                dataTaskWithURL:release.checksumURL
              completionHandler:^(NSData *data, NSURLResponse *checksumResponse,
                                  NSError *checksumError) {
            NSInteger checksumStatus =
                [checksumResponse isKindOfClass:NSHTTPURLResponse.class]
                    ? ((NSHTTPURLResponse *)checksumResponse).statusCode : 0;
            if (checksumError != nil || data.length == 0 ||
                checksumStatus != 200) {
                NSError *resolvedError = checksumError ?: [NSError
                    errorWithDomain:@"TerminalDBUpdater"
                               code:checksumStatus
                           userInfo:@{NSLocalizedDescriptionKey:
                               @"The release checksum could not be downloaded."}];
                dispatch_async(dispatch_get_main_queue(), ^{
                    [strongSelf finishInstallWithError:resolvedError
                                                 window:window];
                });
                return;
            }
            dispatch_async(dispatch_get_global_queue(
                QOS_CLASS_USER_INITIATED, 0), ^{
                NSError *verifyError = nil;
                NSURL *newApp = [strongSelf
                    verifyAndExtractArchiveAtURL:zipPath
                    checksumData:data
                    release:release
                    workingDirectory:[NSURL fileURLWithPath:workingPath]
                    error:&verifyError];
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (newApp == nil) {
                        [strongSelf finishInstallWithError:verifyError
                                                     window:window];
                        return;
                    }
                    NSError *installError = nil;
                    if (![strongSelf swapAndRelaunchWithApp:newApp
                                          workingDirectory:
                                              [NSURL fileURLWithPath:workingPath]
                                                     error:&installError]) {
                        [strongSelf finishInstallWithError:installError
                                                     window:window];
                    }
                });
            });
        }];
        [checksumTask resume];
    }];
    [zipTask resume];
}

- (NSURL *)verifyAndExtractArchiveAtURL:(NSURL *)zipURL
                          checksumData:(NSData *)checksumData
                                release:(TerminalUpdateRelease *)release
                       workingDirectory:(NSURL *)workingDirectory
                                  error:(NSError **)error {
    NSString *checksumText =
        [[NSString alloc] initWithData:checksumData
                              encoding:NSUTF8StringEncoding];
    NSString *expected = [TerminalUpdater
        checksumForAssetNamed:@"TerminalDB-macOS.zip"
                     contents:checksumText ?: @""];
    NSString *actual = [self sha256ForFile:zipURL error:error];
    if (expected.length != 64 || actual == nil ||
        [expected caseInsensitiveCompare:actual] != NSOrderedSame) {
        if (error != NULL && *error == nil) {
            *error = [self errorWithCode:20
                message:@"The update checksum did not match the published release."];
        }
        return nil;
    }

    NSString *listing = [self runTool:@"/usr/bin/unzip"
        arguments:@[@"-Z1", zipURL.path] error:error];
    if (listing == nil) return nil;
    for (NSString *entry in
            [listing componentsSeparatedByCharactersInSet:
                NSCharacterSet.newlineCharacterSet]) {
        if (entry.length == 0) continue;
        NSArray<NSString *> *parts =
            [entry componentsSeparatedByString:@"/"];
        BOOL unsafe = [entry hasPrefix:@"/"] ||
            [parts containsObject:@".."] ||
            (!([entry isEqualToString:@"TerminalDB.app"] ||
               [entry hasPrefix:@"TerminalDB.app/"] ||
               [entry hasPrefix:@"__MACOSX/"]));
        if (unsafe) {
            if (error != NULL) {
                *error = [self errorWithCode:21
                    message:@"The update archive contained an unsafe path."];
            }
            return nil;
        }
    }

    if ([self runTool:@"/usr/bin/ditto"
            arguments:@[@"-x", @"-k", zipURL.path, workingDirectory.path]
                error:error] == nil) {
        return nil;
    }
    NSURL *newApp = [workingDirectory
        URLByAppendingPathComponent:@"TerminalDB.app" isDirectory:YES];
    if (![NSFileManager.defaultManager
            fileExistsAtPath:newApp.path]) {
        if (error != NULL) {
            *error = [self errorWithCode:22
                message:@"The update archive did not contain TerminalDB.app."];
        }
        return nil;
    }
    if ([self runTool:@"/usr/bin/codesign"
            arguments:@[@"--verify", @"--deep", @"--strict", newApp.path]
                error:error] == nil) {
        return nil;
    }
    NSData *currentCertificate =
        [self signingCertificateForApp:NSBundle.mainBundle.bundleURL];
    NSData *newCertificate =
        [self signingCertificateForApp:newApp];
    if (currentCertificate.length > 0 &&
        ![currentCertificate isEqualToData:newCertificate]) {
        if (error != NULL) {
            *error = [self errorWithCode:24
                message:@"The update was signed by a different identity."];
        }
        return nil;
    }
    if ([self runTool:@"/usr/bin/lipo"
            arguments:@[
                [newApp.path
                    stringByAppendingPathComponent:
                        @"Contents/MacOS/TerminalDB"],
                @"-verify_arch", @"arm64", @"x86_64"]
                error:error] == nil) {
        return nil;
    }
    NSBundle *bundle = [NSBundle bundleWithURL:newApp];
    NSString *bundleIdentifier = bundle.bundleIdentifier;
    NSString *bundleVersion = [bundle
        objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    if (![bundleIdentifier
            isEqualToString:NSBundle.mainBundle.bundleIdentifier] ||
        ![bundleVersion isEqualToString:release.version]) {
        if (error != NULL) {
            *error = [self errorWithCode:23
                message:@"The downloaded app identity or version was not expected."];
        }
        return nil;
    }
    return newApp;
}

- (NSData *)signingCertificateForApp:(NSURL *)appURL {
    NSString *directory = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSString stringWithFormat:
            @"terminaldb-certificate-%@", NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager
        createDirectoryAtPath:directory
        withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions : @0700}
        error:nil];
    NSString *prefix =
        [directory stringByAppendingPathComponent:@"certificate"];
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/codesign"];
    task.arguments = @[
        @"--display",
        [@"--extract-certificates=" stringByAppendingString:prefix],
        appURL.path,
    ];
    task.standardOutput = [NSPipe pipe];
    task.standardError = [NSPipe pipe];
    NSError *launchError = nil;
    BOOL launched = [task launchAndReturnError:&launchError];
    if (launched) [task waitUntilExit];
    NSData *certificate = launched && task.terminationStatus == 0
        ? [NSData dataWithContentsOfFile:
            [prefix stringByAppendingString:@"0"]]
        : nil;
    [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
    return certificate;
}

- (BOOL)swapAndRelaunchWithApp:(NSURL *)newApp
               workingDirectory:(NSURL *)workingDirectory
                          error:(NSError **)error {
    NSURL *destination = NSBundle.mainBundle.bundleURL;
    if (![destination.pathExtension isEqualToString:@"app"] ||
        ![NSBundle.mainBundle.bundleIdentifier
            isEqualToString:@"com.terminaldb.app"]) {
        if (error != NULL) {
            *error = [self errorWithCode:30
                message:@"TerminalDB could not confirm its install location."];
        }
        return NO;
    }
    NSString *(^quote)(NSString *) = ^NSString *(NSString *value) {
        return [NSString stringWithFormat:@"'%@'",
            [value stringByReplacingOccurrencesOfString:@"'"
                                             withString:@"'\\''"]];
    };
    NSString *backup = [destination.path stringByAppendingFormat:
        @".old-%@", NSUUID.UUID.UUIDString];
    NSString *scriptPath = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSString stringWithFormat:
            @"terminaldb-install-%@.sh", NSUUID.UUID.UUIDString]];
    NSString *script = [NSString stringWithFormat:
        @"#!/bin/bash\n"
         "set -u\n"
         "while /bin/kill -0 %d 2>/dev/null; do /bin/sleep 0.2; done\n"
         "/bin/mv %@ %@ || exit 1\n"
         "if /bin/mv %@ %@; then\n"
         "  /bin/rm -r %@\n"
         "else\n"
         "  /bin/mv %@ %@\n"
         "  exit 1\n"
         "fi\n"
         "/usr/bin/xattr -dr com.apple.quarantine %@ 2>/dev/null || true\n"
         "/bin/rm -r %@\n"
         "/bin/rm -f %@\n"
         "/usr/bin/open %@\n",
        NSProcessInfo.processInfo.processIdentifier,
        quote(destination.path), quote(backup),
        quote(newApp.path), quote(destination.path),
        quote(backup),
        quote(backup), quote(destination.path),
        quote(destination.path),
        quote(workingDirectory.path),
        quote(scriptPath),
        quote(destination.path)];
    if (![script writeToFile:scriptPath
                  atomically:YES
                    encoding:NSUTF8StringEncoding
                       error:error]) {
        return NO;
    }
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/bash"];
    task.arguments = @[scriptPath];
    if (![task launchAndReturnError:error]) return NO;
    self.activeUpdateDirectory = nil;
    [NSApp terminate:nil];
    return YES;
}

- (void)finishInstallWithError:(NSError *)error window:(NSWindow *)window {
    if (self.activeUpdateDirectory != nil) {
        [NSFileManager.defaultManager
            removeItemAtURL:self.activeUpdateDirectory
            error:nil];
        self.activeUpdateDirectory = nil;
    }
    self.downloading = NO;
    [self notifyStatusChanged];
    [self showAlertWithTitle:@"The update was not installed"
        message:error.localizedDescription ?: @"The update could not be verified."
        window:window];
}

- (void)showAlertWithTitle:(NSString *)title
                   message:(NSString *)message
                    window:(NSWindow *)window {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleInformational;
    alert.messageText = title;
    alert.informativeText = message;
    [alert addButtonWithTitle:@"OK"];
    if (window != nil && window.visible) {
        [alert beginSheetModalForWindow:window completionHandler:nil];
    } else {
        [alert runModal];
    }
}

- (NSString *)sha256ForFile:(NSURL *)fileURL error:(NSError **)error {
    NSInputStream *stream = [NSInputStream
        inputStreamWithURL:fileURL];
    [stream open];
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    uint8_t buffer[64 * 1024];
    while (YES) {
        NSInteger count = [stream read:buffer maxLength:sizeof(buffer)];
        if (count < 0) {
            if (error != NULL) *error = stream.streamError;
            [stream close];
            return nil;
        }
        if (count == 0) break;
        CC_SHA256_Update(&context, buffer, (CC_LONG)count);
    }
    [stream close];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &context);
    NSMutableString *hex =
        [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger index = 0;
         index < CC_SHA256_DIGEST_LENGTH; index++) {
        [hex appendFormat:@"%02x", digest[index]];
    }
    return hex;
}

- (NSString *)runTool:(NSString *)tool
             arguments:(NSArray<NSString *> *)arguments
                 error:(NSError **)error {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:tool];
    task.arguments = arguments;
    NSString *outputPath = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSString stringWithFormat:
            @"terminaldb-tool-%@", NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createFileAtPath:outputPath
                                          contents:nil
                                        attributes:
        @{NSFilePosixPermissions : @0600}];
    NSFileHandle *outputHandle =
        [NSFileHandle fileHandleForWritingAtPath:outputPath];
    if (outputHandle == nil) {
        if (error != NULL) {
            *error = [self errorWithCode:40
                message:@"TerminalDB could not prepare command verification."];
        }
        return nil;
    }
    task.standardOutput = outputHandle;
    task.standardError = outputHandle;
    if (![task launchAndReturnError:error]) {
        [outputHandle closeFile];
        [NSFileManager.defaultManager removeItemAtPath:outputPath error:nil];
        return nil;
    }
    [task waitUntilExit];
    [outputHandle closeFile];
    NSData *data = [NSData dataWithContentsOfFile:outputPath] ?: [NSData data];
    [NSFileManager.defaultManager removeItemAtPath:outputPath error:nil];
    NSString *output =
        [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    if (task.terminationStatus != 0) {
        if (error != NULL) {
            *error = [self errorWithCode:task.terminationStatus
                message:[NSString stringWithFormat:
                    @"%@ failed. %@", tool.lastPathComponent,
                    [output stringByTrimmingCharactersInSet:
                        NSCharacterSet.whitespaceAndNewlineCharacterSet]]];
        }
        return nil;
    }
    return output;
}

- (NSError *)errorWithCode:(NSInteger)code message:(NSString *)message {
    return [NSError errorWithDomain:@"TerminalDBUpdater"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey : message}];
}

+ (BOOL)isVersion:(NSString *)remote newerThan:(NSString *)current {
    NSArray<NSString *> *(^parts)(NSString *) =
        ^NSArray<NSString *> *(NSString *value) {
        NSString *core = [[value componentsSeparatedByString:@"-"]
            firstObject] ?: @"";
        return [core componentsSeparatedByString:@"."];
    };
    NSArray<NSString *> *remoteParts = parts(remote);
    NSArray<NSString *> *currentParts = parts(current);
    NSUInteger count = MAX(remoteParts.count, currentParts.count);
    for (NSUInteger index = 0; index < count; index++) {
        NSInteger a = index < remoteParts.count
            ? remoteParts[index].integerValue : 0;
        NSInteger b = index < currentParts.count
            ? currentParts[index].integerValue : 0;
        if (a != b) return a > b;
    }
    return NO;
}

+ (TerminalUpdateRelease *)bestReleaseFromJSONArray:(id)json {
    if (![json isKindOfClass:NSArray.class]) return nil;
    TerminalUpdateRelease *best = nil;
    for (id value in (NSArray *)json) {
        if (![value isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *releaseJSON = value;
        if ([releaseJSON[@"draft"] boolValue]) continue;
        NSString *tag = [releaseJSON[@"tag_name"]
            isKindOfClass:NSString.class] ? releaseJSON[@"tag_name"] : nil;
        NSString *version = [tag hasPrefix:@"v"]
            ? [tag substringFromIndex:1] : tag;
        if (version.length == 0) continue;
        NSURL *zipURL = nil;
        NSURL *checksumURL = nil;
        NSString *expectedChecksumName = [NSString stringWithFormat:
            @"TerminalDB-v%@-SHA256.txt", version];
        for (id assetValue in releaseJSON[@"assets"]) {
            if (![assetValue isKindOfClass:NSDictionary.class]) continue;
            NSDictionary *asset = assetValue;
            NSString *name = asset[@"name"];
            NSString *download = asset[@"browser_download_url"];
            if (![name isKindOfClass:NSString.class] ||
                ![download isKindOfClass:NSString.class]) {
                continue;
            }
            if ([name isEqualToString:@"TerminalDB-macOS.zip"]) {
                zipURL = [NSURL URLWithString:download];
            } else if ([name isEqualToString:expectedChecksumName]) {
                checksumURL = [NSURL URLWithString:download];
            }
        }
        NSString *htmlURL = releaseJSON[@"html_url"];
        if (zipURL == nil || checksumURL == nil ||
            ![htmlURL isKindOfClass:NSString.class]) {
            continue;
        }
        if (best != nil &&
            ![self isVersion:version newerThan:best.version]) {
            continue;
        }
        TerminalUpdateRelease *candidate =
            [[TerminalUpdateRelease alloc] init];
        candidate.version = version;
        candidate.tagName = tag;
        candidate.notes = [releaseJSON[@"body"]
            isKindOfClass:NSString.class] ? releaseJSON[@"body"] : @"";
        candidate.zipURL = zipURL;
        candidate.checksumURL = checksumURL;
        candidate.releaseURL = [NSURL URLWithString:htmlURL];
        best = candidate;
    }
    return best;
}

+ (NSString *)checksumForAssetNamed:(NSString *)assetName
                            contents:(NSString *)contents {
    NSCharacterSet *space =
        NSCharacterSet.whitespaceCharacterSet;
    for (NSString *line in
            [contents componentsSeparatedByCharactersInSet:
                NSCharacterSet.newlineCharacterSet]) {
        NSArray<NSString *> *raw =
            [line componentsSeparatedByCharactersInSet:space];
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        for (NSString *part in raw) {
            if (part.length > 0) [parts addObject:part];
        }
        if (parts.count >= 2 &&
            [parts.lastObject isEqualToString:assetName] &&
            [parts.firstObject length] == 64) {
            return [parts.firstObject lowercaseString];
        }
    }
    return nil;
}

+ (BOOL)runSelfTests {
    if (![self isVersion:@"0.1.1" newerThan:@"0.1.0"] ||
        ![self isVersion:@"1.0.0" newerThan:@"0.99.99"] ||
        [self isVersion:@"0.1.0" newerThan:@"0.1.0"] ||
        [self isVersion:@"0.0.9" newerThan:@"0.1.0"]) {
        return NO;
    }
    NSString *hash =
        @"0123456789abcdef0123456789abcdef"
         "0123456789abcdef0123456789abcdef";
    NSString *checksums = [NSString stringWithFormat:
        @"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff  "
         "TerminalDB-v0.1.0-macOS-universal.zip\n"
         "%@  TerminalDB-macOS.zip\n", hash];
    if (![[self checksumForAssetNamed:@"TerminalDB-macOS.zip"
                              contents:checksums] isEqualToString:hash] ||
        [self checksumForAssetNamed:@"Missing.zip"
                           contents:checksums] != nil) {
        return NO;
    }
    NSArray *json = @[
        @{
            @"tag_name": @"v0.1.0",
            @"draft": @NO,
            @"body": @"First",
            @"html_url": @"https://example.com/v0.1.0",
            @"assets": @[
                @{@"name": @"TerminalDB-macOS.zip",
                  @"browser_download_url": @"https://example.com/old.zip"},
                @{@"name": @"TerminalDB-v0.1.0-SHA256.txt",
                  @"browser_download_url": @"https://example.com/old.txt"},
            ],
        },
        @{
            @"tag_name": @"v0.2.0",
            @"draft": @NO,
            @"body": @"Second",
            @"html_url": @"https://example.com/v0.2.0",
            @"assets": @[
                @{@"name": @"TerminalDB-macOS.zip",
                  @"browser_download_url": @"https://example.com/new.zip"},
                @{@"name": @"TerminalDB-v0.2.0-SHA256.txt",
                  @"browser_download_url": @"https://example.com/new.txt"},
            ],
        },
    ];
    TerminalUpdateRelease *release =
        [self bestReleaseFromJSONArray:json];
    NSArray *mismatchedChecksumJSON = @[
        @{
            @"tag_name": @"v0.3.0",
            @"draft": @NO,
            @"html_url": @"https://example.com/v0.3.0",
            @"assets": @[
                @{@"name": @"TerminalDB-macOS.zip",
                  @"browser_download_url": @"https://example.com/new.zip"},
                @{@"name": @"TerminalDB-v0.2.0-SHA256.txt",
                  @"browser_download_url": @"https://example.com/wrong.txt"},
            ],
        },
    ];
    return [release.version isEqualToString:@"0.2.0"] &&
        [release.zipURL.absoluteString
            isEqualToString:@"https://example.com/new.zip"] &&
        [self bestReleaseFromJSONArray:mismatchedChecksumJSON] == nil;
}

@end
