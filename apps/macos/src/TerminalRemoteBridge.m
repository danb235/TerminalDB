#import "TerminalRemoteBridge.h"

#import <CoreImage/CoreImage.h>
#import <LocalAuthentication/LocalAuthentication.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>

static NSString *const TerminalRemoteErrorDomain =
    @"com.terminaldb.remote";
static NSString *const TerminalRemoteDefaultBaseURL =
    @"https://dwi1gx38gzrsl.cloudfront.net";
static NSString *const TerminalRemoteDefaultAWSProfile = @"stelao";
static NSString *const TerminalRemoteDefaultAWSRegion = @"us-west-2";
static NSString *const TerminalRemoteDefaultEnrollmentFunction =
    @"terminaldb-remote-dev-control";

static NSURL *TerminalRemoteAccountOnboardingURL(NSString *baseURL) {
    NSURLComponents *components =
        [NSURLComponents componentsWithString:baseURL];
    NSString *scheme = components.scheme.lowercaseString;
    if (components.URL == nil ||
        !([scheme isEqualToString:@"https"] ||
          [scheme isEqualToString:@"http"]) ||
        components.host.length == 0) {
        return nil;
    }
    NSMutableArray<NSURLQueryItem *> *items =
        [components.queryItems mutableCopy] ?: [NSMutableArray array];
    NSIndexSet *existing = [items indexesOfObjectsPassingTest:
        ^BOOL(NSURLQueryItem *item, NSUInteger index, BOOL *stop) {
            (void)index;
            (void)stop;
            return [item.name isEqualToString:@"account"] ||
                [item.name isEqualToString:@"source"];
        }];
    [items removeObjectsAtIndexes:existing];
    [items addObject:[NSURLQueryItem queryItemWithName:@"account"
                                                value:@"create"]];
    [items addObject:[NSURLQueryItem queryItemWithName:@"source"
                                                value:@"desktop"]];
    components.queryItems = items;
    return components.URL;
}

static NSTimeInterval TerminalRemoteOutputDelay(
    BOOL interactive, NSTimeInterval sinceLast) {
    NSTimeInterval interval = interactive ? 0.05 : 0.2;
    NSTimeInterval leadingDelay = interactive ? 0.012 : 0.04;
    return sinceLast >= interval
        ? leadingDelay
        : MAX(leadingDelay, interval - sinceLast);
}

static NSUInteger TerminalRemoteIncompleteUTF8SuffixLength(NSData *data) {
    const uint8_t *bytes = data.bytes;
    NSUInteger length = data.length;
    NSUInteger maximum = MIN((NSUInteger)3, length);
    for (NSUInteger suffixLength = maximum; suffixLength > 0; suffixLength--) {
        NSUInteger start = length - suffixLength;
        uint8_t first = bytes[start];
        NSUInteger expectedLength = 0;
        if (first >= 0xc2 && first <= 0xdf) {
            expectedLength = 2;
        } else if (first >= 0xe0 && first <= 0xef) {
            expectedLength = 3;
        } else if (first >= 0xf0 && first <= 0xf4) {
            expectedLength = 4;
        }
        if (expectedLength == 0 || suffixLength >= expectedLength) continue;
        BOOL validContinuation = YES;
        for (NSUInteger index = start + 1; index < length; index++) {
            if ((bytes[index] & 0xc0) != 0x80) {
                validContinuation = NO;
                break;
            }
        }
        if (validContinuation) return suffixLength;
    }
    return 0;
}

// PTY reads are byte-oriented and may end in the middle of a UTF-8 scalar.
// Decode only complete scalars and leave an incomplete suffix for the next
// batch. Falling back to Latin-1 is reserved for genuinely non-UTF-8 output;
// doing it for a split scalar turns Claude's box drawing into mojibake.
static NSString *TerminalRemoteTakeDecodedOutput(NSMutableData *pending) {
    if (pending.length == 0) return @"";
    NSString *text = [[NSString alloc]
        initWithData:pending encoding:NSUTF8StringEncoding];
    if (text != nil) {
        [pending setLength:0];
        return text;
    }

    NSUInteger suffixLength =
        TerminalRemoteIncompleteUTF8SuffixLength(pending);
    if (suffixLength > 0) {
        NSUInteger prefixLength = pending.length - suffixLength;
        NSData *prefix = [pending subdataWithRange:
            NSMakeRange(0, prefixLength)];
        NSString *prefixText = [[NSString alloc]
            initWithData:prefix encoding:NSUTF8StringEncoding];
        if (prefixText != nil) {
            NSData *suffix = [pending subdataWithRange:
                NSMakeRange(prefixLength, suffixLength)];
            [pending setData:suffix];
            return prefixText;
        }
    }

    text = [[NSString alloc]
        initWithData:pending encoding:NSISOLatin1StringEncoding] ?: @"";
    [pending setLength:0];
    return text;
}

@interface TerminalRemoteBridge ()
@property(nonatomic, copy, readwrite) NSString *connectionState;
@property(nonatomic, copy, readwrite, nullable) NSString *pairingURL;
@property(nonatomic, copy, readwrite, nullable) NSString *statusDetail;
@property(nonatomic, copy, readwrite) NSArray<NSDictionary *> *trustedControllers;
@property(nonatomic, readwrite, getter=isEnabled) BOOL enabled;
@property(nonatomic, readwrite) BOOL accountOwned;
@property(nonatomic, copy) NSString *instanceIdentifier;
@property(nonatomic) int socketDescriptor;
@property(nonatomic) dispatch_source_t readSource;
@property(nonatomic, strong) NSMutableData *readBuffer;
@property(nonatomic) dispatch_queue_t transportQueue;
@property(nonatomic, strong) NSTimer *inventoryTimer;
@property(nonatomic, strong) NSTimer *agentDiscoveryTimer;
@property(nonatomic, strong)
    NSMutableDictionary<NSString *, NSDictionary *> *acceptedRequests;
@property(nonatomic, strong)
    NSMutableDictionary<NSString *, NSMutableData *> *pendingOutputData;
@property(nonatomic, strong)
    NSMutableDictionary<NSString *, NSDictionary *> *pendingOutputDimensions;
@property(nonatomic, strong) NSMutableSet<NSString *> *scheduledOutput;
@property(nonatomic, strong) NSMutableSet<NSString *> *scheduledInteractiveOutput;
@property(nonatomic, strong)
    NSMutableDictionary<NSString *, NSNumber *> *outputScheduleGenerations;
@property(nonatomic, strong)
    NSMutableDictionary<NSString *, NSNumber *> *lastOutputFlushTimes;
@property(nonatomic, strong)
    NSMutableDictionary<NSString *, NSString *> *lastPublishedInputModes;
@property(nonatomic, strong)
    NSMutableDictionary<NSString *, NSDictionary *> *lastAcceptedInputState;
@property(nonatomic, strong)
    NSMutableDictionary<NSString *, NSNumber *> *lastRemoteInputTimes;
@property(nonatomic, strong) NSMutableSet<NSString *> *activeRemoteTabs;
@property(nonatomic, strong)
    NSMutableSet<NSString *> *scheduledViewportSnapshots;
@property(nonatomic) BOOL stopping;
@property(nonatomic) BOOL mayLaunchAgent;
@end

@implementation TerminalRemoteBridge

- (instancetype)initWithDelegate:(id<TerminalRemoteBridgeDelegate>)delegate {
    self = [super init];
    if (self) {
        _delegate = delegate;
        _connectionState = @"disabled";
        _trustedControllers = @[];
        _instanceIdentifier = NSUUID.UUID.UUIDString.lowercaseString;
        _socketDescriptor = -1;
        _readBuffer = [NSMutableData data];
        _transportQueue = dispatch_queue_create(
            "com.terminaldb.remote-bridge", DISPATCH_QUEUE_SERIAL);
        _acceptedRequests = [NSMutableDictionary dictionary];
        _pendingOutputData = [NSMutableDictionary dictionary];
        _pendingOutputDimensions = [NSMutableDictionary dictionary];
        _scheduledOutput = [NSMutableSet set];
        _scheduledInteractiveOutput = [NSMutableSet set];
        _outputScheduleGenerations = [NSMutableDictionary dictionary];
        _lastOutputFlushTimes = [NSMutableDictionary dictionary];
        _lastPublishedInputModes = [NSMutableDictionary dictionary];
        _lastAcceptedInputState = [NSMutableDictionary dictionary];
        _lastRemoteInputTimes = [NSMutableDictionary dictionary];
        _activeRemoteTabs = [NSMutableSet set];
        _scheduledViewportSnapshots = [NSMutableSet set];
    }
    return self;
}

- (NSString *)remoteDirectory {
    NSString *support = [NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
    return [[support stringByAppendingPathComponent:@"TerminalDB"]
        stringByAppendingPathComponent:@"Remote"];
}

- (NSString *)socketPath {
    return [[self remoteDirectory] stringByAppendingPathComponent:@"agent.sock"];
}

- (NSString *)secretPath {
    return [[self remoteDirectory] stringByAppendingPathComponent:@"agent.secret"];
}

- (void)start {
    if (self.stopping) return;
    self.mayLaunchAgent = YES;
    [self ensureInventoryTimer];
    if (self.socketDescriptor >= 0) return;
    dispatch_async(self.transportQueue, ^{
        [self connectOrLaunchAgent];
    });
}

- (void)attachToRunningAgent {
    if (self.stopping) return;
    self.mayLaunchAgent = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.agentDiscoveryTimer == nil) {
            self.agentDiscoveryTimer =
                [NSTimer scheduledTimerWithTimeInterval:2.0
                                                 target:self
                                               selector:@selector(discoverRunningAgent)
                                               userInfo:nil
                                                repeats:YES];
        }
    });
    [self discoverRunningAgent];
}

- (void)discoverRunningAgent {
    if (self.socketDescriptor >= 0 || self.stopping) return;
    dispatch_async(self.transportQueue, ^{
        if ([self connectToAgent]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self ensureInventoryTimer];
            });
        }
    });
}

- (void)ensureInventoryTimer {
    if (self.inventoryTimer != nil) return;
    self.inventoryTimer =
        [NSTimer scheduledTimerWithTimeInterval:5.0
                                         target:self
                                       selector:@selector(publishInventory)
                                       userInfo:nil
                                        repeats:YES];
}

- (void)connectOrLaunchAgent {
    for (NSUInteger attempt = 0; attempt < 40 && !self.stopping; attempt++) {
        if ([self connectToAgent]) return;
        if (attempt == 0) [self launchAgent];
        usleep(100000);
    }
    [self updateState:@"agent-unavailable"
              enabled:NO
           pairingURL:nil
                detail:@"The per-user remote agent could not be started."];
}

- (void)launchAgent {
    NSString *agentPath = [NSBundle.mainBundle
        pathForAuxiliaryExecutable:@"TerminalDBRemoteAgent"];
    if (agentPath.length == 0) {
        [self updateState:@"agent-unavailable"
                  enabled:NO
               pairingURL:nil
                    detail:@"TerminalDBRemoteAgent is missing from the app bundle."];
        return;
    }
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:agentPath];
    task.standardInput = [NSFileHandle fileHandleWithNullDevice];
    task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        [self updateState:@"agent-unavailable"
                  enabled:NO
               pairingURL:nil
                    detail:error.localizedDescription];
    }
}

- (BOOL)connectToAgent {
    if (self.socketDescriptor >= 0) return YES;
    NSData *secretData = [NSData dataWithContentsOfFile:self.secretPath];
    NSString *secret = secretData.length > 0
        ? [[NSString alloc] initWithData:secretData
                                encoding:NSUTF8StringEncoding]
        : nil;
    if (secret.length == 0) return NO;

    int descriptor = socket(AF_UNIX, SOCK_STREAM, 0);
    if (descriptor < 0) return NO;
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    const char *path = self.socketPath.fileSystemRepresentation;
    if (strlen(path) >= sizeof(address.sun_path)) {
        close(descriptor);
        return NO;
    }
    strlcpy(address.sun_path, path, sizeof(address.sun_path));
    if (connect(descriptor, (struct sockaddr *)&address,
                (socklen_t)sizeof(address)) != 0) {
        close(descriptor);
        return NO;
    }

    self.socketDescriptor = descriptor;
    self.readSource = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_READ, (uintptr_t)descriptor, 0,
        self.transportQueue);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.readSource, ^{
        [weakSelf readAvailable];
    });
    dispatch_source_set_cancel_handler(self.readSource, ^{
        close(descriptor);
    });
    dispatch_resume(self.readSource);
    [self sendMessage:@{
        @"type" : @"hello",
        @"secret" : secret,
        @"instanceId" : self.instanceIdentifier,
        @"pid" : @(NSProcessInfo.processInfo.processIdentifier),
    }];
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            [self publishInventory];
        });
    return YES;
}

- (void)readAvailable {
    uint8_t bytes[16384];
    ssize_t count = read(self.socketDescriptor, bytes, sizeof(bytes));
    if (count <= 0) {
        [self disconnectTransport];
        if (!self.stopping) {
            [self updateState:@"reconnecting"
                      enabled:self.enabled
                   pairingURL:self.pairingURL
                        detail:@"Local agent restarted. Reconnecting…"];
            if (self.mayLaunchAgent) {
                dispatch_after(
                    dispatch_time(DISPATCH_TIME_NOW,
                        (int64_t)(0.5 * NSEC_PER_SEC)),
                    self.transportQueue, ^{
                        [self connectOrLaunchAgent];
                    });
            }
        }
        return;
    }
    [self.readBuffer appendBytes:bytes length:(NSUInteger)count];
    const uint8_t newline = '\n';
    while (self.readBuffer.length > 0) {
        NSRange range = [self.readBuffer
            rangeOfData:[NSData dataWithBytes:&newline length:1]
                options:0
                  range:NSMakeRange(0, self.readBuffer.length)];
        if (range.location == NSNotFound) break;
        NSData *frame =
            [self.readBuffer subdataWithRange:NSMakeRange(0, range.location)];
        [self.readBuffer replaceBytesInRange:
            NSMakeRange(0, NSMaxRange(range)) withBytes:NULL length:0];
        if (frame.length == 0) continue;
        NSDictionary *message = [NSJSONSerialization
            JSONObjectWithData:frame options:0 error:nil];
        if ([message isKindOfClass:NSDictionary.class]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self handleMessage:message];
            });
        }
    }
}

- (void)handleMessage:(NSDictionary *)message {
    NSString *type = [message[@"type"] isKindOfClass:NSString.class]
        ? message[@"type"] : @"";
    if ([type isEqualToString:@"remoteStatus"]) {
        NSString *nextState =
            [message[@"state"] isKindOfClass:NSString.class]
                ? message[@"state"] : @"connecting";
        NSString *nextPairingURL =
            [message[@"pairingURL"] isKindOfClass:NSString.class]
                ? message[@"pairingURL"]
                : ([nextState isEqualToString:@"disabled"]
                    ? nil : self.pairingURL);
        if ([message[@"controllers"] isKindOfClass:NSArray.class]) {
            self.trustedControllers = message[@"controllers"];
        }
        self.accountOwned = [message[@"accountOwned"] boolValue];
        [self updateState:nextState
                  enabled:[message[@"enabled"] boolValue]
               pairingURL:nextPairingURL
                    detail:
            [message[@"detail"] isKindOfClass:NSString.class]
                ? message[@"detail"] : nil];
        return;
    }
    if ([type isEqualToString:@"error"]) {
        NSString *detail = [message[@"message"] isKindOfClass:NSString.class]
            ? message[@"message"] : @"Remote agent failed.";
        [self updateState:@"error"
                  enabled:self.enabled
               pairingURL:self.pairingURL
                    detail:detail];
        return;
    }
    if ([type isEqualToString:@"accountBootstrap"]) {
        NSString *urlValue = [message[@"url"] isKindOfClass:NSString.class]
            ? message[@"url"] : @"";
        NSURL *url = TerminalRemoteAccountOnboardingURL(urlValue);
        if (url != nil) {
            [NSWorkspace.sharedWorkspace openURL:url];
            [self updateState:@"connecting"
                      enabled:self.enabled
                   pairingURL:self.pairingURL
                        detail:@"Finish account setup in the browser. This Mac will connect automatically."];
        } else {
            [self updateState:@"error"
                      enabled:self.enabled
                   pairingURL:self.pairingURL
                        detail:@"The account setup URL was invalid."];
        }
        return;
    }
    if ([type isEqualToString:@"snapshotRequest"]) {
        NSString *tabIdentifier = message[@"tabId"];
        NSString *controllerIdentifier = message[@"controllerId"];
        NSDictionary *viewport =
            [self.delegate terminalRemoteViewportForTabIdentifier:tabIdentifier];
        if (viewport != nil && controllerIdentifier.length > 0) {
            [self sendViewport:viewport
                 tabIdentifier:tabIdentifier
                    controller:controllerIdentifier];
        }
        return;
    }
    if ([type isEqualToString:@"resize"]) {
        NSString *tabIdentifier = [message[@"tabId"] isKindOfClass:NSString.class]
            ? message[@"tabId"] : @"";
        NSString *controllerIdentifier =
            [message[@"controllerId"] isKindOfClass:NSString.class]
                ? message[@"controllerId"] : @"";
        BOOL active = message[@"active"] == nil || [message[@"active"] boolValue];
        NSUInteger columns = [message[@"columns"] unsignedIntegerValue];
        NSUInteger rows = [message[@"rows"] unsignedIntegerValue];
        NSError *error = nil;
        BOOL accepted =
            [self.delegate terminalRemoteBridge:self
                    resizeTerminalTabIdentifier:tabIdentifier
                                         columns:columns
                                            rows:rows
                                          active:active
                                           error:&error];
        if (accepted && active) {
            [self.activeRemoteTabs addObject:tabIdentifier];
        } else {
            [self.activeRemoteTabs removeObject:tabIdentifier];
        }
        if (!accepted || !active || controllerIdentifier.length == 0) return;

        // TUI processes redraw after SIGWINCH. Let their coalesced PTY output
        // arrive, then replace it with an exact screen at the new controller
        // geometry so borders and bottom controls cannot be reflowed.
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.16 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                NSDictionary *viewport =
                    [self.delegate terminalRemoteViewportForTabIdentifier:
                        tabIdentifier];
                if (viewport != nil) {
                    [self sendViewport:viewport
                         tabIdentifier:tabIdentifier
                            controller:controllerIdentifier];
                }
            });
        return;
    }
    if ([type isEqualToString:@"ackStatusRequest"]) {
        NSString *requestIdentifier = message[@"requestId"];
        NSString *controllerIdentifier = message[@"controllerId"];
        if (requestIdentifier.length == 0 ||
            controllerIdentifier.length == 0) {
            return;
        }
        NSDictionary *previous = self.acceptedRequests[requestIdentifier];
        if (previous != nil) {
            [self sendMessage:previous];
        } else {
            [self sendAcknowledgementForRequest:requestIdentifier
                                     controller:controllerIdentifier
                                       accepted:NO
                                         detail:
                @"The Mac has no record of accepting this request."
                                    inputStream:nil
                                   inputThrough:nil];
        }
        return;
    }
    if ([type isEqualToString:@"remoteCommand"]) {
        [self handleRemoteCommand:message];
    }
}

- (void)handleRemoteCommand:(NSDictionary *)message {
    NSString *requestIdentifier = message[@"requestId"];
    NSString *controllerIdentifier = message[@"controllerId"];
    if (requestIdentifier.length == 0 || controllerIdentifier.length == 0) {
        return;
    }
    NSDictionary *previous = self.acceptedRequests[requestIdentifier];
    if (previous != nil) {
        [self sendMessage:previous];
        return;
    }
    NSTimeInterval expiresAt = [message[@"expiresAt"] doubleValue];
    if (expiresAt > 0 &&
        expiresAt < NSDate.date.timeIntervalSince1970 * 1000.0) {
        [self sendAcknowledgementForRequest:requestIdentifier
                                controller:controllerIdentifier
                                  accepted:NO
                                    detail:@"The command expired before the Mac accepted it."
                               inputStream:nil
                              inputThrough:nil];
        return;
    }

    NSString *route = message[@"route"];
    NSString *tabIdentifier = message[@"tabId"];
    NSError *error = nil;
    BOOL accepted = NO;
    if ([route isEqualToString:@"pty.input"]) {
        accepted = [self.delegate terminalRemoteBridge:self
                                            writeInput:message[@"input"] ?: @""
                                       toTabIdentifier:tabIdentifier
                                                 error:&error];
        NSNumber *inputSequence = [message[@"inputSequence"]
            isKindOfClass:NSNumber.class] ? message[@"inputSequence"] : nil;
        NSString *inputStream = [message[@"inputStreamId"]
            isKindOfClass:NSString.class] ? message[@"inputStreamId"] : nil;
        if (accepted && inputSequence.unsignedIntegerValue > 0 &&
            inputStream.length > 0) {
            self.lastAcceptedInputState[tabIdentifier] = @{
                @"inputStreamId" : inputStream,
                @"inputThrough" : inputSequence,
            };
            self.lastRemoteInputTimes[tabIdentifier] =
                @(NSDate.date.timeIntervalSince1970);
        }
    } else if ([route isEqualToString:@"tab.create"]) {
        accepted = [self.delegate terminalRemoteBridge:self
                               createTabFromIdentifier:tabIdentifier
                                                 error:&error];
    } else if ([route isEqualToString:@"tab.select"]) {
        accepted = [self.delegate terminalRemoteBridge:self
                                   selectTabIdentifier:tabIdentifier
                                                 error:&error];
    } else if ([route isEqualToString:@"tab.close"]) {
        accepted = [self.delegate terminalRemoteBridge:self
                                    closeTabIdentifier:tabIdentifier
                                                 error:&error];
        if (accepted) {
            [self.activeRemoteTabs removeObject:tabIdentifier];
            [self.lastAcceptedInputState removeObjectForKey:tabIdentifier];
            [self.lastRemoteInputTimes removeObjectForKey:tabIdentifier];
            dispatch_async(self.transportQueue, ^{
                [self.pendingOutputData removeObjectForKey:tabIdentifier];
                [self.pendingOutputDimensions removeObjectForKey:tabIdentifier];
                [self.scheduledOutput removeObject:tabIdentifier];
                [self.scheduledInteractiveOutput removeObject:tabIdentifier];
                self.outputScheduleGenerations[tabIdentifier] = @(
                    [self.outputScheduleGenerations[tabIdentifier]
                        unsignedIntegerValue] + 1);
            });
        }
    } else if ([route isEqualToString:@"account.switch"]) {
        accepted = [self.delegate terminalRemoteBridge:self
                                         switchAccount:message[@"accountId"] ?: @""
                                      forTabIdentifier:tabIdentifier
                                                 error:&error];
    } else if ([route isEqualToString:@"usage.refresh"]) {
        [self.delegate terminalRemoteBridgeDidRequestUsageRefresh:self];
        accepted = YES;
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                [self publishInventory];
            });
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                [self publishInventory];
            });
    }
    [self sendAcknowledgementForRequest:requestIdentifier
                            controller:controllerIdentifier
                              accepted:accepted
                                detail:error.localizedDescription
                           inputStream:[message[@"inputStreamId"]
                               isKindOfClass:NSString.class]
                               ? message[@"inputStreamId"] : nil
                          inputThrough:[message[@"inputSequence"]
                               isKindOfClass:NSNumber.class]
                               ? message[@"inputSequence"] : nil];
}

- (void)sendAcknowledgementForRequest:(NSString *)requestIdentifier
                           controller:(NSString *)controllerIdentifier
                             accepted:(BOOL)accepted
                               detail:(NSString *)detail
                          inputStream:(NSString *)inputStream
                         inputThrough:(NSNumber *)inputThrough {
    NSMutableDictionary *ack = [@{
        @"type" : @"ack",
        @"requestId" : requestIdentifier,
        @"controllerId" : controllerIdentifier,
        @"accepted" : @(accepted),
    } mutableCopy];
    if (detail.length > 0) ack[@"detail"] = detail;
    if (inputStream.length > 0 && inputThrough.unsignedIntegerValue > 0) {
        ack[@"inputStreamId"] = inputStream;
        ack[@"inputThrough"] = inputThrough;
    }
    self.acceptedRequests[requestIdentifier] = ack;
    if (self.acceptedRequests.count > 512) {
        NSString *oldest = self.acceptedRequests.allKeys.firstObject;
        if (oldest != nil) [self.acceptedRequests removeObjectForKey:oldest];
    }
    [self sendMessage:ack];
}

- (void)publishInventory {
    if (self.socketDescriptor < 0) return;
    NSDictionary *instance =
        [self.delegate terminalRemoteInventoryForBridge:self];
    if (instance == nil) return;
    [self sendMessage:@{
        @"type" : @"inventory",
        @"instance" : instance,
    }];
}

- (void)enableWithBaseURL:(NSString *)baseURL
           enrollmentCode:(NSString *)enrollmentCode {
    [self start];
    [self sendMessage:@{
        @"type" : @"enable",
        @"baseURL" : baseURL,
        @"enrollmentCode" : enrollmentCode,
    }];
}

- (void)disable {
    [self sendMessage:@{@"type" : @"disable"}];
}

- (void)createPairing {
    [self sendMessage:@{@"type" : @"createPairing"}];
}

- (void)createAccountWithBaseURL:(NSString *)baseURL {
    [self start];
    [self sendMessage:@{
        @"type" : @"createAccountBootstrap",
        @"baseURL" : baseURL,
    }];
}

- (void)resetAccountPassword:(NSString *)password {
    if (password.length == 0) return;
    [self sendMessage:@{
        @"type" : @"resetAccountPassword",
        @"password" : password,
    }];
}

- (void)deleteAccount {
    [self sendMessage:@{@"type" : @"deleteAccount"}];
}

- (void)refreshControllers {
    [self sendMessage:@{@"type" : @"refreshControllers"}];
}

- (void)revokeControllerWithIdentifier:(NSString *)controllerIdentifier {
    if (controllerIdentifier.length == 0) return;
    [self sendMessage:@{
        @"type" : @"revokeController",
        @"controllerId" : controllerIdentifier,
    }];
}

- (void)publishOutputData:(NSData *)data
            tabIdentifier:(NSString *)tabIdentifier
                     rows:(NSUInteger)rows
                  columns:(NSUInteger)columns
                inputMode:(NSString *)inputMode {
    if (!self.enabled || data.length == 0 || tabIdentifier.length == 0) return;
    NSString *resolvedInputMode = inputMode.length > 0 ? inputMode : @"secure";
    NSDictionary *acceptedInput = self.lastAcceptedInputState[tabIdentifier];
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    NSTimeInterval lastRemoteInput =
        [self.lastRemoteInputTimes[tabIdentifier] doubleValue];
    BOOL interactive =
        [self.activeRemoteTabs containsObject:tabIdentifier] &&
        lastRemoteInput > 0 && now - lastRemoteInput <= 1.25;
    NSString *previousInputMode = self.lastPublishedInputModes[tabIdentifier];
    if (![previousInputMode isEqualToString:resolvedInputMode]) {
        self.lastPublishedInputModes[tabIdentifier] = resolvedInputMode;
        // Older agents preserve arbitrary inventory fields but do not know
        // the per-output inputMode key. Publish the transition immediately so
        // rolling upgrades still enter secure mode before password input.
        [self publishInventory];
    }
    dispatch_async(self.transportQueue, ^{
        NSMutableData *pending = self.pendingOutputData[tabIdentifier];
        if (pending == nil) {
            pending = [NSMutableData data];
            self.pendingOutputData[tabIdentifier] = pending;
        }
        [pending appendData:data];
        NSMutableDictionary *dimensions = [@{
            @"rows" : @(rows),
            @"columns" : @(columns),
            @"inputMode" : resolvedInputMode,
            @"interactive" : @(interactive),
        } mutableCopy];
        if (acceptedInput[@"inputStreamId"] != nil &&
            acceptedInput[@"inputThrough"] != nil) {
            dimensions[@"inputStreamId"] = acceptedInput[@"inputStreamId"];
            dimensions[@"inputThrough"] = acceptedInput[@"inputThrough"];
        }
        self.pendingOutputDimensions[tabIdentifier] = dimensions;
        BOOL alreadyScheduled =
            [self.scheduledOutput containsObject:tabIdentifier];
        BOOL alreadyInteractive =
            [self.scheduledInteractiveOutput containsObject:tabIdentifier];
        if (alreadyScheduled && (!interactive || alreadyInteractive)) return;
        [self.scheduledOutput addObject:tabIdentifier];
        if (interactive) {
            [self.scheduledInteractiveOutput addObject:tabIdentifier];
        }
        NSUInteger generation =
            [self.outputScheduleGenerations[tabIdentifier] unsignedIntegerValue] + 1;
        self.outputScheduleGenerations[tabIdentifier] = @(generation);
        NSTimeInterval now = NSDate.date.timeIntervalSince1970;
        NSTimeInterval last =
            [self.lastOutputFlushTimes[tabIdentifier] doubleValue];
        NSTimeInterval sinceLast = last > 0 ? now - last : DBL_MAX;
        NSTimeInterval delay =
            TerminalRemoteOutputDelay(interactive, sinceLast);
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW,
                (int64_t)(delay * NSEC_PER_SEC)),
            self.transportQueue, ^{
                if ([self.outputScheduleGenerations[tabIdentifier]
                        unsignedIntegerValue] != generation) {
                    return;
                }
                [self flushOutputForTabIdentifier:tabIdentifier];
            });
    });
}

- (void)flushOutputForTabIdentifier:(NSString *)tabIdentifier {
    NSMutableData *pending = self.pendingOutputData[tabIdentifier];
    NSDictionary *dimensions = self.pendingOutputDimensions[tabIdentifier];
    [self.pendingOutputDimensions removeObjectForKey:tabIdentifier];
    [self.scheduledOutput removeObject:tabIdentifier];
    [self.scheduledInteractiveOutput removeObject:tabIdentifier];
    self.lastOutputFlushTimes[tabIdentifier] =
        @(NSDate.date.timeIntervalSince1970);
    NSString *chunk = TerminalRemoteTakeDecodedOutput(pending);
    if (pending.length == 0) {
        [self.pendingOutputData removeObjectForKey:tabIdentifier];
    }
    NSUInteger decodedLength = chunk.length;
    if (chunk.length > 12000) {
        NSRange suffix = [chunk
            rangeOfComposedCharacterSequencesForRange:
                NSMakeRange(chunk.length - 12000, 12000)];
        chunk = [chunk substringWithRange:suffix];
    }
    if (chunk.length == 0) return;
    NSMutableDictionary *message = [@{
        @"type" : @"output",
        @"tabId" : tabIdentifier,
        @"text" : chunk,
        @"rows" : dimensions[@"rows"] ?: @24,
        @"columns" : dimensions[@"columns"] ?: @80,
        @"inputMode" : dimensions[@"inputMode"] ?: @"secure",
        @"overflow" : @(decodedLength > 12000),
    } mutableCopy];
    if (dimensions[@"inputStreamId"] != nil &&
        dimensions[@"inputThrough"] != nil) {
        message[@"inputStreamId"] = dimensions[@"inputStreamId"];
        message[@"inputThrough"] = dimensions[@"inputThrough"];
    }
    [self sendMessage:message];
}

+ (BOOL)runUTF8OutputDecodingSelfTests {
    const uint8_t splitPrefix[] = {0xe2, 0x94};
    NSMutableData *split = [NSMutableData
        dataWithBytes:splitPrefix length:sizeof(splitPrefix)];
    NSString *first = TerminalRemoteTakeDecodedOutput(split);
    const uint8_t splitSuffix[] = {0x8c};
    [split appendBytes:splitSuffix length:sizeof(splitSuffix)];
    NSString *second = TerminalRemoteTakeDecodedOutput(split);

    const uint8_t invalidByte[] = {0xff};
    NSMutableData *invalid = [NSMutableData
        dataWithBytes:invalidByte length:sizeof(invalidByte)];
    NSString *fallback = TerminalRemoteTakeDecodedOutput(invalid);
    NSURL *accountURL = TerminalRemoteAccountOnboardingURL(
        @"https://remote.example.invalid/app?stage=dev");
    NSDictionary<NSString *, NSString *> *accountQuery = @{
        @"account" : @"create",
        @"source" : @"desktop",
        @"stage" : @"dev",
    };
    NSMutableDictionary<NSString *, NSString *> *actualQuery =
        [NSMutableDictionary dictionary];
    for (NSURLQueryItem *item in
         [NSURLComponents componentsWithURL:accountURL
                    resolvingAgainstBaseURL:NO].queryItems) {
        if (item.name.length > 0 && item.value.length > 0) {
            actualQuery[item.name] = item.value;
        }
    }
    return first.length == 0 &&
        [second isEqualToString:@"┌"] &&
        [fallback isEqualToString:@"ÿ"] &&
        [accountURL.path isEqualToString:@"/app"] &&
        [actualQuery isEqualToDictionary:accountQuery] &&
        TerminalRemoteAccountOnboardingURL(@"not a URL") == nil &&
        TerminalRemoteAccountOnboardingURL(@"javascript://example.invalid") == nil &&
        split.length == 0 && invalid.length == 0 &&
        fabs(TerminalRemoteOutputDelay(YES, 1.0) - 0.012) < 0.0001 &&
        fabs(TerminalRemoteOutputDelay(YES, 0.02) - 0.03) < 0.0001 &&
        fabs(TerminalRemoteOutputDelay(NO, 1.0) - 0.04) < 0.0001 &&
        fabs(TerminalRemoteOutputDelay(NO, 0.1) - 0.1) < 0.0001;
}

- (void)publishViewportForTabIdentifier:(NSString *)tabIdentifier {
    if (!self.enabled || tabIdentifier.length == 0) return;
    if ([self.scheduledViewportSnapshots containsObject:tabIdentifier]) return;
    [self.scheduledViewportSnapshots addObject:tabIdentifier];
    // Let the PTY's coalesced raw output arrive first, then replace it with
    // the exact native screen. This captures TerminalDB-only ledger blocks
    // without duplicating every normal terminal output batch.
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            [self.scheduledViewportSnapshots removeObject:tabIdentifier];
            NSDictionary *viewport =
                [self.delegate terminalRemoteViewportForTabIdentifier:tabIdentifier];
            NSString *text = [viewport[@"text"] isKindOfClass:NSString.class]
                ? viewport[@"text"] : @"";
            if (viewport == nil || text.length == 0) return;
            [self sendViewport:viewport
                 tabIdentifier:tabIdentifier
                    controller:nil];
        });
}

- (void)sendViewport:(NSDictionary *)viewport
        tabIdentifier:(NSString *)tabIdentifier
           controller:(NSString *)controllerIdentifier {
    NSString *text = [viewport[@"text"] isKindOfClass:NSString.class]
        ? viewport[@"text"] : @"";
    if (text.length == 0 || tabIdentifier.length == 0) return;

    // Keep each encrypted WebSocket payload comfortably below API Gateway's
    // 32 KB frame boundary even when the snapshot contains multi-byte text.
    const NSUInteger maximumChunkCharacters = 4000;
    NSMutableArray<NSString *> *chunks = [NSMutableArray array];
    NSUInteger offset = 0;
    while (offset < text.length) {
        NSUInteger length = MIN(maximumChunkCharacters, text.length - offset);
        NSRange range = [text rangeOfComposedCharacterSequencesForRange:
            NSMakeRange(offset, length)];
        if (NSMaxRange(range) > text.length) {
            range.length = text.length - range.location;
        }
        [chunks addObject:[text substringWithRange:range]];
        offset = NSMaxRange(range);
    }

    NSString *snapshotIdentifier = NSUUID.UUID.UUIDString;
    NSDictionary *acceptedInput = self.lastAcceptedInputState[tabIdentifier];
    for (NSUInteger index = 0; index < chunks.count; index++) {
        NSMutableDictionary *message = [@{
            @"type" : @"snapshot",
            @"tabId" : tabIdentifier,
            @"text" : chunks[index],
            @"rows" : viewport[@"rows"] ?: @24,
            @"columns" : viewport[@"columns"] ?: @80,
            @"inputMode" : viewport[@"inputMode"] ?: @"secure",
            @"snapshotId" : snapshotIdentifier,
            @"chunkIndex" : @(index),
            @"chunkCount" : @(chunks.count),
        } mutableCopy];
        if (controllerIdentifier.length > 0) {
            message[@"controllerId"] = controllerIdentifier;
        }
        if (acceptedInput[@"inputStreamId"] != nil &&
            acceptedInput[@"inputThrough"] != nil) {
            message[@"inputStreamId"] = acceptedInput[@"inputStreamId"];
            message[@"inputThrough"] = acceptedInput[@"inputThrough"];
        }
        [self sendMessage:message];
    }
}

- (void)sendMessage:(NSDictionary *)message {
    dispatch_async(self.transportQueue, ^{
        if (self.socketDescriptor < 0) return;
        NSMutableData *data = [[NSJSONSerialization
            dataWithJSONObject:message options:0 error:nil] mutableCopy];
        if (data.length == 0) return;
        const uint8_t newline = '\n';
        [data appendBytes:&newline length:1];
        const uint8_t *bytes = data.bytes;
        NSUInteger offset = 0;
        while (offset < data.length) {
            ssize_t written = write(self.socketDescriptor, bytes + offset,
                data.length - offset);
            if (written <= 0) break;
            offset += (NSUInteger)written;
        }
    });
}

- (void)updateState:(NSString *)state
              enabled:(BOOL)enabled
           pairingURL:(NSString *)pairingURL
                detail:(NSString *)detail {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.connectionState = state;
        self.enabled = enabled;
        self.pairingURL = pairingURL;
        self.statusDetail = detail;
        if ([self.delegate
                respondsToSelector:
                    @selector(terminalRemoteBridgeStatusDidChange:)]) {
            [self.delegate terminalRemoteBridgeStatusDidChange:self];
        }
    });
}

- (void)disconnectTransport {
    if (self.readSource != nil) {
        dispatch_source_cancel(self.readSource);
        self.readSource = nil;
    } else if (self.socketDescriptor >= 0) {
        close(self.socketDescriptor);
    }
    self.socketDescriptor = -1;
    [self.readBuffer setLength:0];
}

- (void)stop {
    self.stopping = YES;
    [self.inventoryTimer invalidate];
    self.inventoryTimer = nil;
    [self.agentDiscoveryTimer invalidate];
    self.agentDiscoveryTimer = nil;
    dispatch_async(self.transportQueue, ^{
        [self disconnectTransport];
    });
}

@end

@interface TerminalRemoteWindowController ()
@property(nonatomic, weak) TerminalRemoteBridge *bridge;
@property(nonatomic, strong) NSTextField *statusLabel;
@property(nonatomic, strong) NSTextField *detailLabel;
@property(nonatomic, strong) NSImageView *pairingQRCode;
@property(nonatomic, strong) NSButton *primaryButton;
@property(nonatomic, strong) NSButton *pairPhoneButton;
@property(nonatomic, strong) NSButton *pairingCopyButton;
@property(nonatomic, strong) NSButton *advancedButton;
@property(nonatomic, strong) NSButton *disableButton;
@property(nonatomic, strong) NSButton *createAccountButton;
@property(nonatomic, strong) NSButton *connectAccountButton;
@property(nonatomic, strong) NSButton *resetAccountButton;
@property(nonatomic, strong) NSButton *deleteAccountButton;
@property(nonatomic, strong) NSTextField *controllersLabel;
@property(nonatomic, strong) NSPopUpButton *controllersPopUp;
@property(nonatomic, strong) NSButton *revokeControllerButton;
@property(nonatomic) BOOL automaticSetupInProgress;
@property(nonatomic) BOOL openBrowserWhenPairingReady;
@property(nonatomic) BOOL showPhonePairing;
@property(nonatomic, copy, nullable) NSString *automaticSetupError;
@property(nonatomic, copy, nullable) NSString *lastAutomaticallyOpenedPairingURL;
@property(nonatomic) BOOL accountSetupInProgress;
@property(nonatomic, copy, nullable) NSString *pendingAccountBaseURL;
@property(nonatomic, copy, nullable) NSString *pendingAccountEnrollmentCode;
@end

@implementation TerminalRemoteWindowController

- (instancetype)initWithBridge:(TerminalRemoteBridge *)bridge {
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 500, 600)
                  styleMask:NSWindowStyleMaskTitled |
                            NSWindowStyleMaskClosable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    self = [super initWithWindow:window];
    if (self) {
        _bridge = bridge;
        window.title = @"TerminalDB Remote Control";
        window.releasedWhenClosed = NO;
        [self buildInterface];
        [self refresh];
    }
    return self;
}

- (NSTextField *)labelWithString:(NSString *)string
                            font:(NSFont *)font
                           color:(NSColor *)color {
    NSTextField *label = [NSTextField labelWithString:string];
    label.font = font;
    label.textColor = color;
    label.maximumNumberOfLines = 0;
    label.lineBreakMode = NSLineBreakByWordWrapping;
    return label;
}

- (NSString *)configuredValueForKey:(NSString *)key
                       defaultValue:(NSString *)defaultValue {
    NSString *configured =
        [NSUserDefaults.standardUserDefaults stringForKey:key];
    configured = [configured
        stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return configured.length > 0 ? configured : defaultValue;
}

- (NSURL *)awsExecutableURL {
    NSArray<NSString *> *candidates = @[
        @"/opt/homebrew/bin/aws",
        @"/usr/local/bin/aws",
        @"/usr/bin/aws",
    ];
    for (NSString *candidate in candidates) {
        if ([NSFileManager.defaultManager
                isExecutableFileAtPath:candidate]) {
            return [NSURL fileURLWithPath:candidate];
        }
    }
    return nil;
}

- (void)requestAutomaticEnrollment:
    (void (^)(NSString *_Nullable code, NSError *_Nullable error))completion {
    NSURL *awsURL = [self awsExecutableURL];
    if (awsURL == nil) {
        NSError *error = [NSError
            errorWithDomain:TerminalRemoteErrorDomain
                       code:20
                   userInfo:@{NSLocalizedDescriptionKey:
                       @"AWS CLI was not found. Install it or use Advanced Setup."}];
        completion(nil, error);
        return;
    }
    NSString *profile = [self
        configuredValueForKey:@"TerminalDBRemoteAWSProfile"
                  defaultValue:TerminalRemoteDefaultAWSProfile];
    NSString *region = [self
        configuredValueForKey:@"TerminalDBRemoteAWSRegion"
                  defaultValue:TerminalRemoteDefaultAWSRegion];
    NSString *functionName = [self
        configuredValueForKey:@"TerminalDBRemoteEnrollmentFunction"
                  defaultValue:TerminalRemoteDefaultEnrollmentFunction];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSFileManager *files = NSFileManager.defaultManager;
        NSString *directory = [NSTemporaryDirectory()
            stringByAppendingPathComponent:[NSString
                stringWithFormat:@"terminaldb-enrollment-%@",
                    NSUUID.UUID.UUIDString.lowercaseString]];
        NSError *directoryError = nil;
        if (![files createDirectoryAtPath:directory
              withIntermediateDirectories:YES
                               attributes:@{NSFilePosixPermissions:@0700}
                                    error:&directoryError]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, directoryError);
            });
            return;
        }
        NSString *responsePath =
            [directory stringByAppendingPathComponent:@"response.json"];
        NSTask *task = [[NSTask alloc] init];
        task.executableURL = awsURL;
        task.arguments = @[
            @"lambda", @"invoke",
            @"--function-name", functionName,
            @"--cli-binary-format", @"raw-in-base64-out",
            @"--payload", @"{\"action\":\"createEnrollment\"}",
            responsePath,
            @"--profile", profile,
            @"--region", region,
            @"--no-cli-pager",
            @"--output", @"json",
        ];
        NSPipe *standardOutput = [NSPipe pipe];
        NSPipe *standardError = [NSPipe pipe];
        task.standardInput = [NSFileHandle fileHandleWithNullDevice];
        task.standardOutput = standardOutput;
        task.standardError = standardError;
        NSError *launchError = nil;
        BOOL launched = [task launchAndReturnError:&launchError];
        if (launched) [task waitUntilExit];
        NSData *errorData =
            [standardError.fileHandleForReading readDataToEndOfFile];
        NSError *resultError = launchError;
        NSString *code = nil;
        if (launched && task.terminationStatus == 0) {
            [files setAttributes:@{NSFilePosixPermissions:@0600}
                    ofItemAtPath:responsePath
                           error:nil];
            NSData *data = [NSData dataWithContentsOfFile:responsePath];
            NSDictionary *response = data.length > 0
                ? [NSJSONSerialization JSONObjectWithData:data
                                                   options:0
                                                     error:nil]
                : nil;
            code = [response[@"enrollmentCode"]
                isKindOfClass:NSString.class]
                ? response[@"enrollmentCode"] : nil;
            if (code.length == 0) {
                resultError = [NSError
                    errorWithDomain:TerminalRemoteErrorDomain
                               code:21
                           userInfo:@{NSLocalizedDescriptionKey:
                               @"AWS returned an invalid enrollment response."}];
            }
        } else if (resultError == nil) {
            NSString *detail = [[NSString alloc]
                initWithData:errorData encoding:NSUTF8StringEncoding];
            detail = [detail
                stringByTrimmingCharactersInSet:
                    NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (detail.length > 300) {
                detail = [detail substringFromIndex:detail.length - 300];
            }
            NSString *message = detail.length > 0
                ? [NSString stringWithFormat:
                    @"AWS enrollment failed: %@", detail]
                : @"AWS enrollment failed. Sign in to the configured AWS profile or use Advanced Setup.";
            resultError = [NSError
                errorWithDomain:TerminalRemoteErrorDomain
                           code:22
                       userInfo:@{NSLocalizedDescriptionKey:message}];
        }
        [files removeItemAtPath:directory error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(code, resultError);
        });
    });
}

- (void)beginAutomaticSetupOpeningBrowser:(BOOL)openBrowser {
    if (self.automaticSetupInProgress) return;
    self.automaticSetupInProgress = YES;
    self.automaticSetupError = nil;
    self.openBrowserWhenPairingReady = openBrowser;
    self.lastAutomaticallyOpenedPairingURL = self.bridge.pairingURL;
    self.showPhonePairing = !openBrowser;
    [self refresh];
    __weak typeof(self) weakSelf = self;
    [self requestAutomaticEnrollment:^(NSString *code, NSError *error) {
        TerminalRemoteWindowController *strongSelf = weakSelf;
        if (strongSelf == nil) return;
        strongSelf.automaticSetupInProgress = NO;
        if (error != nil || code.length == 0) {
            strongSelf.openBrowserWhenPairingReady = NO;
            strongSelf.automaticSetupError =
                error.localizedDescription ?: @"Automatic setup failed.";
            [strongSelf refresh];
            return;
        }
        NSString *baseURL = [strongSelf
            configuredValueForKey:@"TerminalDBRemoteBaseURL"
                      defaultValue:TerminalRemoteDefaultBaseURL];
        [NSUserDefaults.standardUserDefaults setObject:baseURL
            forKey:@"TerminalDBRemoteBaseURL"];
        [strongSelf.bridge enableWithBaseURL:baseURL enrollmentCode:code];
        [strongSelf refresh];
    }];
}

- (void)buildInterface {
    NSView *content = self.window.contentView;
    content.wantsLayer = YES;
    content.layer.backgroundColor =
        [NSColor colorWithRed:0.063 green:0.063 blue:0.075 alpha:1].CGColor;

    NSTextField *eyebrow =
        [self labelWithString:@"REMOTE CONTROL"
                        font:[NSFont monospacedSystemFontOfSize:10
                                                       weight:NSFontWeightBold]
                       color:[NSColor colorWithWhite:0.55 alpha:1]];
    NSTextField *title =
        [self labelWithString:@"Your terminals, in one click"
                        font:[NSFont systemFontOfSize:23
                                             weight:NSFontWeightSemibold]
                       color:[NSColor colorWithWhite:0.91 alpha:1]];
    NSTextField *privacy =
        [self labelWithString:
            @"Terminal content and Claude credentials stay on this Mac. "
             "AWS relays end-to-end encrypted messages only."
                        font:[NSFont systemFontOfSize:12]
                       color:[NSColor colorWithWhite:0.58 alpha:1]];
    self.statusLabel =
        [self labelWithString:@"DISABLED"
                        font:[NSFont monospacedSystemFontOfSize:11
                                                       weight:NSFontWeightBold]
                       color:[NSColor colorWithWhite:0.55 alpha:1]];
    self.detailLabel =
        [self labelWithString:@"Remote Control is off."
                        font:[NSFont systemFontOfSize:11]
                       color:[NSColor colorWithWhite:0.58 alpha:1]];

    self.pairingQRCode = [[NSImageView alloc] init];
    self.pairingQRCode.imageScaling = NSImageScaleProportionallyUpOrDown;

    self.primaryButton =
        [NSButton buttonWithTitle:@"Open Remote Web App"
                           target:self
                           action:@selector(primaryAction:)];
    self.primaryButton.bezelStyle = NSBezelStyleRounded;
    self.primaryButton.keyEquivalent = @"\r";
    self.pairPhoneButton =
        [NSButton buttonWithTitle:@"Pair a Phone"
                           target:self
                           action:@selector(pairPhone:)];
    self.pairPhoneButton.bezelStyle = NSBezelStyleRounded;
    self.pairingCopyButton =
        [NSButton buttonWithTitle:@"Copy Pairing Link"
                           target:self
                           action:@selector(copyPairingLink:)];
    self.pairingCopyButton.bezelStyle = NSBezelStyleRounded;
    self.advancedButton =
        [NSButton buttonWithTitle:@"Advanced Setup…"
                           target:self
                           action:@selector(showAdvancedSetup:)];
    self.advancedButton.bezelStyle = NSBezelStyleInline;
    self.disableButton =
        [NSButton buttonWithTitle:@"Turn Off"
                           target:self
                           action:@selector(disableRemote:)];
    self.disableButton.bezelStyle = NSBezelStyleInline;
    NSTextField *accountTitle =
        [self labelWithString:@"TERMINALDB ACCOUNT"
                        font:[NSFont monospacedSystemFontOfSize:10
                                                       weight:NSFontWeightBold]
                       color:[NSColor colorWithRed:0.255 green:0.839 blue:0.792 alpha:1]];
    NSTextField *accountDetail =
        [self labelWithString:
            @"Create an account to open this Mac's sessions from any signed-in browser. "
             "Passwords stay in Cognito's secure browser flow."
                        font:[NSFont systemFontOfSize:11]
                       color:[NSColor colorWithWhite:0.58 alpha:1]];
    self.createAccountButton =
        [NSButton buttonWithTitle:@"Create Account"
                           target:self
                           action:@selector(createAccount:)];
    self.createAccountButton.bezelStyle = NSBezelStyleRounded;
    self.connectAccountButton =
        [NSButton buttonWithTitle:@"Connect Account…"
                           target:self
                           action:@selector(connectAccount:)];
    self.connectAccountButton.bezelStyle = NSBezelStyleRounded;
    self.resetAccountButton =
        [NSButton buttonWithTitle:@"Change Password…"
                           target:self
                           action:@selector(resetAccountLogin:)];
    self.resetAccountButton.bezelStyle = NSBezelStyleRounded;
    self.deleteAccountButton =
        [NSButton buttonWithTitle:@"Delete Account…"
                           target:self
                           action:@selector(deleteAccount:)];
    self.deleteAccountButton.bezelStyle = NSBezelStyleRounded;
    self.controllersLabel =
        [self labelWithString:@"TRUSTED BROWSERS"
                        font:[NSFont monospacedSystemFontOfSize:10
                                                       weight:NSFontWeightBold]
                       color:[NSColor colorWithWhite:0.55 alpha:1]];
    self.controllersPopUp =
        [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.controllersPopUp.bezelStyle = NSBezelStyleRounded;
    self.revokeControllerButton =
        [NSButton buttonWithTitle:@"Revoke Selected"
                           target:self
                           action:@selector(revokeSelectedController:)];
    self.revokeControllerButton.bezelStyle = NSBezelStyleRounded;

    NSArray<NSView *> *views = @[
        eyebrow, title, privacy, self.statusLabel, self.detailLabel,
        self.pairingQRCode, self.primaryButton, self.pairPhoneButton,
        self.pairingCopyButton, self.advancedButton, self.disableButton,
        accountTitle, accountDetail, self.createAccountButton,
        self.connectAccountButton, self.resetAccountButton,
        self.deleteAccountButton,
        self.controllersLabel, self.controllersPopUp,
        self.revokeControllerButton,
    ];
    for (NSView *view in views) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
        [eyebrow.topAnchor constraintEqualToAnchor:content.topAnchor constant:28],
        [eyebrow.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:28],
        [title.topAnchor constraintEqualToAnchor:eyebrow.bottomAnchor constant:8],
        [title.leadingAnchor constraintEqualToAnchor:eyebrow.leadingAnchor],
        [title.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-28],
        [privacy.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:10],
        [privacy.leadingAnchor constraintEqualToAnchor:eyebrow.leadingAnchor],
        [privacy.trailingAnchor constraintEqualToAnchor:title.trailingAnchor],
        [self.statusLabel.topAnchor constraintEqualToAnchor:privacy.bottomAnchor constant:20],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:eyebrow.leadingAnchor],
        [self.detailLabel.centerYAnchor constraintEqualToAnchor:self.statusLabel.centerYAnchor],
        [self.detailLabel.leadingAnchor constraintEqualToAnchor:self.statusLabel.trailingAnchor constant:12],
        [self.detailLabel.trailingAnchor constraintEqualToAnchor:title.trailingAnchor],
        [self.primaryButton.topAnchor constraintEqualToAnchor:self.statusLabel.bottomAnchor constant:22],
        [self.primaryButton.leadingAnchor constraintEqualToAnchor:eyebrow.leadingAnchor],
        [self.primaryButton.widthAnchor constraintEqualToConstant:210],
        [self.primaryButton.heightAnchor constraintEqualToConstant:38],
        [self.pairPhoneButton.centerYAnchor constraintEqualToAnchor:self.primaryButton.centerYAnchor],
        [self.pairPhoneButton.leadingAnchor constraintEqualToAnchor:self.primaryButton.trailingAnchor constant:10],
        [self.pairPhoneButton.widthAnchor constraintEqualToConstant:116],
        [self.pairingQRCode.topAnchor constraintEqualToAnchor:self.primaryButton.bottomAnchor constant:18],
        [self.pairingQRCode.trailingAnchor constraintEqualToAnchor:title.trailingAnchor],
        [self.pairingQRCode.widthAnchor constraintEqualToConstant:92],
        [self.pairingQRCode.heightAnchor constraintEqualToConstant:92],
        [self.pairingCopyButton.topAnchor constraintEqualToAnchor:self.primaryButton.bottomAnchor constant:20],
        [self.pairingCopyButton.leadingAnchor constraintEqualToAnchor:eyebrow.leadingAnchor],
        [self.advancedButton.topAnchor constraintEqualToAnchor:self.pairingCopyButton.bottomAnchor constant:10],
        [self.advancedButton.leadingAnchor constraintEqualToAnchor:eyebrow.leadingAnchor],
        [self.disableButton.centerYAnchor constraintEqualToAnchor:self.advancedButton.centerYAnchor],
        [self.disableButton.leadingAnchor constraintEqualToAnchor:self.advancedButton.trailingAnchor constant:14],
        [accountTitle.topAnchor constraintEqualToAnchor:self.advancedButton.bottomAnchor constant:22],
        [accountTitle.leadingAnchor constraintEqualToAnchor:eyebrow.leadingAnchor],
        [accountDetail.topAnchor constraintEqualToAnchor:accountTitle.bottomAnchor constant:7],
        [accountDetail.leadingAnchor constraintEqualToAnchor:eyebrow.leadingAnchor],
        [accountDetail.trailingAnchor constraintEqualToAnchor:title.trailingAnchor],
        [self.createAccountButton.topAnchor constraintEqualToAnchor:accountDetail.bottomAnchor constant:10],
        [self.createAccountButton.leadingAnchor constraintEqualToAnchor:eyebrow.leadingAnchor],
        [self.createAccountButton.widthAnchor constraintEqualToConstant:145],
        [self.createAccountButton.heightAnchor constraintEqualToConstant:34],
        [self.connectAccountButton.centerYAnchor constraintEqualToAnchor:self.createAccountButton.centerYAnchor],
        [self.connectAccountButton.leadingAnchor constraintEqualToAnchor:self.createAccountButton.trailingAnchor constant:10],
        [self.connectAccountButton.widthAnchor constraintEqualToConstant:155],
        [self.connectAccountButton.heightAnchor constraintEqualToConstant:34],
        [self.resetAccountButton.topAnchor constraintEqualToAnchor:self.createAccountButton.bottomAnchor constant:10],
        [self.resetAccountButton.leadingAnchor constraintEqualToAnchor:eyebrow.leadingAnchor],
        [self.resetAccountButton.widthAnchor constraintEqualToConstant:145],
        [self.resetAccountButton.heightAnchor constraintEqualToConstant:32],
        [self.deleteAccountButton.centerYAnchor constraintEqualToAnchor:self.resetAccountButton.centerYAnchor],
        [self.deleteAccountButton.leadingAnchor constraintEqualToAnchor:self.resetAccountButton.trailingAnchor constant:10],
        [self.deleteAccountButton.widthAnchor constraintEqualToConstant:155],
        [self.deleteAccountButton.heightAnchor constraintEqualToConstant:32],
        [self.controllersLabel.topAnchor constraintEqualToAnchor:self.resetAccountButton.bottomAnchor constant:20],
        [self.controllersLabel.leadingAnchor constraintEqualToAnchor:eyebrow.leadingAnchor],
        [self.controllersPopUp.topAnchor constraintEqualToAnchor:self.controllersLabel.bottomAnchor constant:8],
        [self.controllersPopUp.leadingAnchor constraintEqualToAnchor:eyebrow.leadingAnchor],
        [self.controllersPopUp.widthAnchor constraintEqualToConstant:280],
        [self.controllersPopUp.heightAnchor constraintEqualToConstant:30],
        [self.revokeControllerButton.centerYAnchor constraintEqualToAnchor:self.controllersPopUp.centerYAnchor],
        [self.revokeControllerButton.leadingAnchor constraintEqualToAnchor:self.controllersPopUp.trailingAnchor constant:10],
        [self.revokeControllerButton.trailingAnchor constraintLessThanOrEqualToAnchor:title.trailingAnchor],
    ]];
}

- (void)refresh {
    TerminalRemoteBridge *bridge = self.bridge;
    if (self.pendingAccountEnrollmentCode.length > 0 &&
        !bridge.enabled &&
        [bridge.connectionState isEqualToString:@"disabled"]) {
        NSString *baseURL = self.pendingAccountBaseURL;
        NSString *code = self.pendingAccountEnrollmentCode;
        self.pendingAccountBaseURL = nil;
        self.pendingAccountEnrollmentCode = nil;
        [bridge enableWithBaseURL:baseURL enrollmentCode:code];
    }
    BOOL accountSetupFailed =
        [bridge.connectionState isEqualToString:@"error"] ||
        [bridge.connectionState isEqualToString:@"agent-unavailable"];
    if (self.accountSetupInProgress && accountSetupFailed) {
        self.pendingAccountBaseURL = nil;
        self.pendingAccountEnrollmentCode = nil;
        self.accountSetupInProgress = NO;
    } else if (self.accountSetupInProgress &&
               self.pendingAccountEnrollmentCode.length == 0 &&
               [bridge.connectionState isEqualToString:@"live"]) {
        self.accountSetupInProgress = NO;
    }
    NSString *visibleState = bridge.connectionState;
    if (self.automaticSetupInProgress || self.accountSetupInProgress) {
        visibleState = @"setting up";
    }
    else if (self.automaticSetupError.length > 0) visibleState = @"setup needed";
    else if ([visibleState isEqualToString:@"disabled"]) visibleState = @"ready";
    self.statusLabel.stringValue = visibleState.uppercaseString;
    if (self.accountSetupInProgress) {
        self.detailLabel.stringValue =
            @"Connecting this Mac to your TerminalDB account…";
    } else if (self.automaticSetupInProgress) {
        self.detailLabel.stringValue =
            @"Securely enrolling this Mac and preparing the browser…";
    } else if (self.automaticSetupError.length > 0) {
        self.detailLabel.stringValue = self.automaticSetupError;
    } else {
        self.detailLabel.stringValue = bridge.statusDetail ?:
            (bridge.enabled
                ? @"The encrypted relay is active."
                : @"Click once to mirror your open TerminalDB tabs.");
    }
    BOOL hasPhonePairing =
        self.showPhonePairing && bridge.pairingURL.length > 0;
    self.pairingQRCode.image = hasPhonePairing
        ? [self QRImageForString:bridge.pairingURL size:184] : nil;
    self.pairingQRCode.hidden = !hasPhonePairing;
    self.pairingCopyButton.hidden = !hasPhonePairing;
    self.pairingCopyButton.enabled = hasPhonePairing;
    BOOL setupInProgress =
        self.automaticSetupInProgress || self.accountSetupInProgress;
    self.primaryButton.enabled = !setupInProgress;
    self.primaryButton.title = self.automaticSetupInProgress
        ? @"Opening…" : @"Open Remote Web App";
    self.pairPhoneButton.enabled = !setupInProgress;
    self.createAccountButton.enabled = !setupInProgress;
    self.connectAccountButton.enabled = !setupInProgress;
    self.resetAccountButton.enabled = !setupInProgress && bridge.accountOwned;
    self.deleteAccountButton.enabled = !setupInProgress && bridge.accountOwned;
    self.disableButton.hidden = !bridge.enabled;
    [self.controllersPopUp removeAllItems];
    for (NSDictionary *controller in bridge.trustedControllers) {
        NSString *name =
            [controller[@"name"] isKindOfClass:NSString.class]
                ? controller[@"name"] : @"Web browser";
        BOOL connected = [controller[@"connected"] boolValue];
        NSMenuItem *item = [[NSMenuItem alloc]
            initWithTitle:[NSString stringWithFormat:@"%@ · %@",
                name, connected ? @"connected" : @"offline"]
                   action:nil
            keyEquivalent:@""];
        item.representedObject = controller[@"controllerId"];
        [self.controllersPopUp.menu addItem:item];
    }
    if (bridge.trustedControllers.count == 0) {
        [self.controllersPopUp addItemWithTitle:
            bridge.enabled ? @"No paired controllers" : @"Remote Control is off"];
    }
    self.controllersPopUp.enabled =
        bridge.enabled && bridge.trustedControllers.count > 0;
    self.revokeControllerButton.enabled = self.controllersPopUp.enabled;
    if (self.openBrowserWhenPairingReady &&
        bridge.pairingURL.length > 0 &&
        ![bridge.pairingURL
            isEqualToString:self.lastAutomaticallyOpenedPairingURL]) {
        NSString *pairingURL = bridge.pairingURL;
        self.lastAutomaticallyOpenedPairingURL = pairingURL;
        self.openBrowserWhenPairingReady = NO;
        self.showPhonePairing = NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSWorkspace.sharedWorkspace openURL:
                [NSURL URLWithString:pairingURL]];
        });
    }
    if ([bridge.connectionState isEqualToString:@"live"]) {
        self.statusLabel.textColor =
            [NSColor colorWithRed:0.706 green:0.89 blue:0.302 alpha:1];
    } else if ([bridge.connectionState isEqualToString:@"error"] ||
               [bridge.connectionState isEqualToString:@"agent-unavailable"]) {
        self.statusLabel.textColor =
            [NSColor colorWithRed:0.937 green:0.396 blue:0.341 alpha:1];
    } else {
        self.statusLabel.textColor =
            [NSColor colorWithRed:0.89 green:0.675 blue:0.306 alpha:1];
    }
}

- (void)showWindow:(id)sender {
    [super showWindow:sender];
    [self.bridge refreshControllers];
}

- (void)pairPhone:(id)sender {
    (void)sender;
    self.automaticSetupError = nil;
    self.openBrowserWhenPairingReady = NO;
    self.showPhonePairing = YES;
    if (!self.bridge.enabled) {
        [self beginAutomaticSetupOpeningBrowser:NO];
        return;
    }
    [self.bridge createPairing];
    [self refresh];
}

- (void)disableRemote:(id)sender {
    (void)sender;
    self.showPhonePairing = NO;
    self.openBrowserWhenPairingReady = NO;
    [self.bridge disable];
}

- (void)revokeSelectedController:(id)sender {
    (void)sender;
    NSString *controllerIdentifier =
        self.controllersPopUp.selectedItem.representedObject;
    if (controllerIdentifier.length == 0) return;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Revoke this trusted controller?";
    alert.informativeText =
        @"The browser will immediately lose remote access. Local terminal work continues.";
    [alert addButtonWithTitle:@"Revoke Controller"];
    [alert addButtonWithTitle:@"Cancel"];
    [alert beginSheetModalForWindow:self.window
                  completionHandler:^(NSModalResponse response) {
        if (response == NSAlertFirstButtonReturn) {
            [self.bridge revokeControllerWithIdentifier:controllerIdentifier];
        }
    }];
}

- (NSImage *)QRImageForString:(NSString *)value size:(CGFloat)size {
    if (value.length == 0) return nil;
    CIFilter *filter = [CIFilter filterWithName:@"CIQRCodeGenerator"];
    [filter setValue:[value dataUsingEncoding:NSUTF8StringEncoding]
              forKey:@"inputMessage"];
    [filter setValue:@"M" forKey:@"inputCorrectionLevel"];
    CIImage *output = filter.outputImage;
    if (output == nil) return nil;
    CGFloat scale = size / MAX(output.extent.size.width,
                               output.extent.size.height);
    output = [output imageByApplyingTransform:
        CGAffineTransformMakeScale(scale, scale)];
    NSCIImageRep *representation =
        [NSCIImageRep imageRepWithCIImage:output];
    NSImage *image = [[NSImage alloc] initWithSize:
        NSMakeSize(size, size)];
    [image addRepresentation:representation];
    return image;
}

- (void)createAccount:(id)sender {
    (void)sender;
    NSString *baseURL = [self
        configuredValueForKey:@"TerminalDBRemoteBaseURL"
                  defaultValue:TerminalRemoteDefaultBaseURL];
    if (TerminalRemoteAccountOnboardingURL(baseURL) == nil) {
        self.automaticSetupError =
            @"Set a valid Remote web URL in Advanced Setup first.";
        [self refresh];
        return;
    }
    self.automaticSetupError = nil;
    self.accountSetupInProgress = YES;
    [self.bridge createAccountWithBaseURL:baseURL];
    [self refresh];
}

- (void)connectAccount:(id)sender {
    (void)sender;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Connect this Mac to your TerminalDB account";
    alert.informativeText = self.bridge.enabled
        ? @"Paste the short-lived code from the web app. Connecting the account ends the current one-time remote session, then starts a new account session without changing this Mac's identity."
        : @"Paste the short-lived code from the web app. TerminalDB will enroll this Mac without changing its local identity.";
    [alert addButtonWithTitle:@"Connect Account"];
    [alert addButtonWithTitle:@"Cancel"];

    NSTextField *baseURL = [[NSTextField alloc] init];
    baseURL.placeholderString = @"Remote web URL";
    baseURL.stringValue = [self
        configuredValueForKey:@"TerminalDBRemoteBaseURL"
                  defaultValue:TerminalRemoteDefaultBaseURL];
    NSSecureTextField *enrollment = [[NSSecureTextField alloc] init];
    enrollment.placeholderString = @"15-minute account code";
    NSStackView *fields = [NSStackView stackViewWithViews:@[
        [NSTextField labelWithString:@"Web URL"], baseURL,
        [NSTextField labelWithString:@"Account code"], enrollment,
    ]];
    fields.orientation = NSUserInterfaceLayoutOrientationVertical;
    fields.alignment = NSLayoutAttributeLeading;
    fields.spacing = 6;
    fields.frame = NSMakeRect(0, 0, 380, 100);
    [baseURL.widthAnchor constraintEqualToConstant:380].active = YES;
    [enrollment.widthAnchor constraintEqualToConstant:380].active = YES;
    alert.accessoryView = fields;

    [alert beginSheetModalForWindow:self.window
                  completionHandler:^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) return;
        NSString *url = [baseURL.stringValue
            stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString *code = [enrollment.stringValue
            stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (TerminalRemoteAccountOnboardingURL(url) == nil || code.length == 0) {
            self.automaticSetupError =
                @"Enter a valid deployed web URL and a fresh account code.";
            [self refresh];
            return;
        }
        [NSUserDefaults.standardUserDefaults setObject:url
            forKey:@"TerminalDBRemoteBaseURL"];
        self.automaticSetupError = nil;
        self.accountSetupInProgress = YES;
        self.showPhonePairing = NO;
        self.openBrowserWhenPairingReady = NO;
        if (self.bridge.enabled) {
            self.pendingAccountBaseURL = url;
            self.pendingAccountEnrollmentCode = code;
            [self.bridge disable];
        } else {
            [self.bridge enableWithBaseURL:url enrollmentCode:code];
        }
        [self refresh];
    }];
}

- (void)authorizeAccountAction:(NSString *)reason
                     completion:(void (^)(BOOL approved))completion {
    LAContext *context = [[LAContext alloc] init];
    context.localizedCancelTitle = @"Cancel";
    NSError *availabilityError = nil;
    if (![context canEvaluatePolicy:LAPolicyDeviceOwnerAuthentication
                              error:&availabilityError]) {
        self.automaticSetupError = availabilityError.localizedDescription ?:
            @"Mac authentication is unavailable.";
        [self refresh];
        completion(NO);
        return;
    }
    [context evaluatePolicy:LAPolicyDeviceOwnerAuthentication
            localizedReason:reason
                      reply:^(BOOL success, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!success && error.code != LAErrorUserCancel &&
                error.code != LAErrorAppCancel) {
                self.automaticSetupError = error.localizedDescription ?:
                    @"Mac authentication failed.";
                [self refresh];
            }
            completion(success);
        });
    }];
}

- (void)resetAccountLogin:(id)sender {
    (void)sender;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Change TerminalDB account password";
    alert.informativeText =
        @"This changes the Cognito password and signs out every account browser. Your existing authenticator and passkeys remain required.";
    [alert addButtonWithTitle:@"Authenticate and Change"];
    [alert addButtonWithTitle:@"Cancel"];
    NSSecureTextField *password = [[NSSecureTextField alloc] init];
    password.placeholderString = @"New password";
    NSSecureTextField *confirmation = [[NSSecureTextField alloc] init];
    confirmation.placeholderString = @"Confirm new password";
    NSStackView *fields = [NSStackView stackViewWithViews:@[
        [NSTextField labelWithString:
            @"12+ characters with upper/lowercase, a number, and a symbol"],
        password,
        confirmation,
    ]];
    fields.orientation = NSUserInterfaceLayoutOrientationVertical;
    fields.spacing = 7;
    fields.frame = NSMakeRect(0, 0, 380, 86);
    [password.widthAnchor constraintEqualToConstant:380].active = YES;
    [confirmation.widthAnchor constraintEqualToConstant:380].active = YES;
    alert.accessoryView = fields;
    [alert beginSheetModalForWindow:self.window
                  completionHandler:^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) return;
        NSString *next = password.stringValue;
        BOOL strong = next.length >= 12 &&
            [next rangeOfCharacterFromSet:NSCharacterSet.lowercaseLetterCharacterSet].location != NSNotFound &&
            [next rangeOfCharacterFromSet:NSCharacterSet.uppercaseLetterCharacterSet].location != NSNotFound &&
            [next rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet].location != NSNotFound &&
            [next rangeOfCharacterFromSet:NSCharacterSet.alphanumericCharacterSet.invertedSet].location != NSNotFound;
        if (!strong || ![next isEqualToString:confirmation.stringValue]) {
            self.automaticSetupError = !strong
                ? @"The new password does not meet the account policy."
                : @"The new passwords do not match.";
            [self refresh];
            return;
        }
        [self authorizeAccountAction:@"Reset your TerminalDB account login"
                           completion:^(BOOL approved) {
            if (!approved) return;
            self.automaticSetupError = nil;
            [self.bridge resetAccountPassword:next];
            [self refresh];
        }];
    }];
}

- (void)deleteAccount:(id)sender {
    (void)sender;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Permanently delete TerminalDB account?";
    alert.informativeText =
        @"This removes the Cognito login, enrolled Macs, active account sessions, and trusted account browsers. One-time links that were never attached to the account are unaffected.";
    [alert addButtonWithTitle:@"Authenticate and Delete"];
    [alert addButtonWithTitle:@"Cancel"];
    NSTextField *confirmation = [[NSTextField alloc] init];
    confirmation.placeholderString = @"Type DELETE";
    confirmation.frame = NSMakeRect(0, 0, 380, 24);
    alert.accessoryView = confirmation;
    [alert beginSheetModalForWindow:self.window
                  completionHandler:^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) return;
        if (![confirmation.stringValue isEqualToString:@"DELETE"]) {
            self.automaticSetupError = @"Type DELETE exactly to confirm account deletion.";
            [self refresh];
            return;
        }
        [self authorizeAccountAction:@"Delete your TerminalDB account"
                           completion:^(BOOL approved) {
            if (!approved) return;
            self.automaticSetupError = nil;
            [self.bridge deleteAccount];
            [self refresh];
        }];
    }];
}

- (void)primaryAction:(id)sender {
    (void)sender;
    self.automaticSetupError = nil;
    self.showPhonePairing = NO;
    if (!self.bridge.enabled) {
        [self beginAutomaticSetupOpeningBrowser:YES];
        return;
    }
    self.openBrowserWhenPairingReady = YES;
    self.lastAutomaticallyOpenedPairingURL = self.bridge.pairingURL;
    [self.bridge createPairing];
    [self refresh];
}

- (void)showAdvancedSetup:(id)sender {
    (void)sender;
    if (self.bridge.enabled) {
        NSAlert *activeAlert = [[NSAlert alloc] init];
        activeAlert.messageText = @"Disable Remote Control First";
        activeAlert.informativeText =
            @"End the current remote session before changing this Mac's deployment or account enrollment.";
        [activeAlert addButtonWithTitle:@"OK"];
        [activeAlert beginSheetModalForWindow:self.window completionHandler:nil];
        return;
    }
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Advanced Remote Setup";
    alert.informativeText =
        @"Use an enrollment code from your TerminalDB web account, a custom deployment, or the AWS operator workflow.";
    [alert addButtonWithTitle:@"Enable and Open"];
    [alert addButtonWithTitle:@"Cancel"];

    NSTextField *baseURL = [[NSTextField alloc] init];
    baseURL.placeholderString = @"CloudFront web URL";
    baseURL.stringValue = [self
        configuredValueForKey:@"TerminalDBRemoteBaseURL"
                  defaultValue:TerminalRemoteDefaultBaseURL];
    NSSecureTextField *enrollment = [[NSSecureTextField alloc] init];
    enrollment.placeholderString = @"15-minute enrollment code";
    NSStackView *fields = [NSStackView stackViewWithViews:@[
        [NSTextField labelWithString:@"Web URL"], baseURL,
        [NSTextField labelWithString:@"Enrollment code"], enrollment,
    ]];
    fields.orientation = NSUserInterfaceLayoutOrientationVertical;
    fields.alignment = NSLayoutAttributeLeading;
    fields.spacing = 6;
    fields.frame = NSMakeRect(0, 0, 380, 100);
    [baseURL.widthAnchor constraintEqualToConstant:380].active = YES;
    [enrollment.widthAnchor constraintEqualToConstant:380].active = YES;
    alert.accessoryView = fields;
    [alert beginSheetModalForWindow:self.window
                  completionHandler:^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) return;
        NSString *url = [baseURL.stringValue
            stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString *code = [enrollment.stringValue
            stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (url.length == 0 || code.length == 0) {
            self.automaticSetupError =
                @"Enter both the deployed web URL and a fresh enrollment code.";
            [self refresh];
            return;
        }
        [NSUserDefaults.standardUserDefaults setObject:url
            forKey:@"TerminalDBRemoteBaseURL"];
        self.automaticSetupError = nil;
        self.openBrowserWhenPairingReady = YES;
        self.showPhonePairing = NO;
        [self.bridge enableWithBaseURL:url enrollmentCode:code];
        [self refresh];
    }];
}

- (void)copyPairingLink:(id)sender {
    (void)sender;
    if (self.bridge.pairingURL.length == 0) return;
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard
        setString:self.bridge.pairingURL
          forType:NSPasteboardTypeString];
}

@end
