#import "ClaudeAPI.h"

NSNotificationName const ClaudeAPIConfigurationDidChangeNotification =
    @"ClaudeAPIConfigurationDidChangeNotification";
NSString *const ClaudeAIProviderSubscription = @"subscription";
NSString *const ClaudeAIProviderAPI = @"api";

static NSString *const ClaudeAPIKeyDefaultsKey = @"ClaudeAPIKey";
static NSString *const ClaudeAPISelectedModelDefaultsKey =
    @"ClaudeAPISelectedModel";
static NSString *const ClaudeAPIModelsDefaultsKey = @"ClaudeAPIModels";
static NSString *const ClaudeAIProviderDefaultsKey = @"ClaudeAIProvider";
static NSString *const ClaudeSubscriptionModelDefaultsKey =
    @"ClaudeSubscriptionModel";
static NSString *const ClaudeAPIErrorDomain = @"com.terminaldb.app.ClaudeAPI";
static NSString *const ClaudeAPIVersion = @"2023-06-01";

static NSError *ClaudeError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:ClaudeAPIErrorDomain
                               code:code
                           userInfo:@{
        NSLocalizedDescriptionKey : message ?: @"Claude API request failed.",
    }];
}

static NSString *ClaudeAPIErrorMessage(NSData *data,
                                       NSHTTPURLResponse *response) {
    NSDictionary *json = data.length > 0
        ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil]
        : nil;
    NSDictionary *error =
        [json[@"error"] isKindOfClass:NSDictionary.class] ? json[@"error"] : nil;
    NSString *message =
        [error[@"message"] isKindOfClass:NSString.class] ? error[@"message"] : nil;
    if (message.length > 0) return message;
    if (response.statusCode == 401) {
        return @"Anthropic rejected this API key. Check the key and try again.";
    }
    if (response.statusCode == 429) {
        return @"The Claude API rate limit was reached. Try again shortly.";
    }
    if (response.statusCode > 0) {
        return [NSString stringWithFormat:@"Claude API returned HTTP %ld.",
            (long)response.statusCode];
    }
    return @"Claude API request failed.";
}

static NSArray<NSDictionary *> *ClaudeAPIValidModels(id saved) {
    if (![saved isKindOfClass:NSArray.class]) return @[];
    NSMutableArray<NSDictionary *> *valid = [NSMutableArray array];
    for (id candidate in saved) {
        if (![candidate isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *model = candidate;
        NSString *identifier =
            [model[@"id"] isKindOfClass:NSString.class] ? model[@"id"] : nil;
        if (identifier.length == 0) continue;
        NSMutableDictionary *clean =
            [@{@"id" : identifier} mutableCopy];
        for (NSString *key in @[@"display_name", @"created_at", @"type"]) {
            if ([model[key] isKindOfClass:NSString.class]) {
                clean[key] = model[key];
            }
        }
        [valid addObject:clean];
    }
    return valid;
}

@interface ClaudeAPIConfiguration ()
@property(nonatomic, copy) NSArray<NSDictionary *> *models;
@property(nonatomic, copy, nullable) NSString *selectedModelID;
@property(nonatomic, copy) NSString *chatProvider;
@property(nonatomic, copy) NSString *subscriptionModelID;
@end

@interface ClaudeCodeClient ()
@property(nonatomic, copy) NSString *executable;
@property(nonatomic, copy) NSString *configDirectory;
@property(nonatomic, copy) NSString *workingDirectory;
@property(nonatomic, copy) NSString *model;
@property(nonatomic, copy, nullable) NSString *requestedSessionID;
@property(nonatomic, copy, nullable) NSString *returnedSessionID;
@property(nonatomic, copy, nullable) NSString *returnedModel;
@property(nonatomic, strong, nullable) NSTask *task;
@property(nonatomic, strong, nullable) NSPipe *inputPipe;
@property(nonatomic, strong, nullable) NSPipe *outputPipe;
@property(nonatomic, strong, nullable) NSPipe *errorPipe;
@property(nonatomic, strong) NSMutableData *lineBuffer;
@property(nonatomic, strong) NSMutableData *errorOutputBuffer;
@property(nonatomic, strong) NSMutableString *streamedText;
@property(nonatomic, copy, nullable) NSString *resultText;
@property(nonatomic, copy, nullable) NSString *resultError;
@property(nonatomic, copy, nullable) ClaudeAPITextDeltaBlock textDelta;
@property(nonatomic, copy, nullable) ClaudeCodeCompletionBlock completion;
@property(nonatomic) dispatch_queue_t parserQueue;
@property(nonatomic) BOOL finished;
@end

@implementation ClaudeCodeClient

+ (nullable NSString *)textDeltaFromEvent:(NSDictionary *)event {
    if (![event[@"type"] isEqualToString:@"stream_event"]) return nil;
    NSDictionary *streamEvent =
        [event[@"event"] isKindOfClass:NSDictionary.class]
            ? event[@"event"] : nil;
    if (![streamEvent[@"type"]
            isEqualToString:@"content_block_delta"]) {
        return nil;
    }
    NSDictionary *delta =
        [streamEvent[@"delta"] isKindOfClass:NSDictionary.class]
            ? streamEvent[@"delta"] : nil;
    return [delta[@"type"] isEqualToString:@"text_delta"] &&
            [delta[@"text"] isKindOfClass:NSString.class]
        ? delta[@"text"] : nil;
}

+ (BOOL)runStreamParsingSelfTests {
    NSDictionary *event = @{
        @"type" : @"stream_event",
        @"event" : @{
            @"type" : @"content_block_delta",
            @"delta" : @{@"type" : @"text_delta", @"text" : @"hello"},
        },
    };
    NSDictionary *irrelevant = @{
        @"type" : @"stream_event",
        @"event" : @{
            @"type" : @"message_start",
            @"message" : @{},
        },
    };
    if (![[self textDeltaFromEvent:event] isEqualToString:@"hello"] ||
        [self textDeltaFromEvent:irrelevant] != nil) {
        return NO;
    }

    ClaudeCodeClient *client = [[ClaudeCodeClient alloc]
        initWithExecutable:@"/bin/false"
          configDirectory:@"/tmp"
         workingDirectory:@"/tmp"
                    model:@""
                sessionID:nil];
    NSString *first =
        @"not-json\n{\"type\":\"stream_event\",\"event\":{\"type\":"
         "\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",";
    NSString *second =
        @"\"text\":\"split\"}},\"session_id\":\"test-session\"}\n";
    [client consumeOutputData:
        [first dataUsingEncoding:NSUTF8StringEncoding] final:NO];
    if (client.streamedText.length != 0) return NO;
    [client consumeOutputData:
        [second dataUsingEncoding:NSUTF8StringEncoding] final:NO];
    return [client.streamedText isEqualToString:@"split"] &&
        [client.returnedSessionID isEqualToString:@"test-session"];
}

- (instancetype)initWithExecutable:(NSString *)executable
                  configDirectory:(NSString *)configDirectory
                 workingDirectory:(NSString *)workingDirectory
                            model:(NSString *)model
                        sessionID:(NSString *)sessionID {
    self = [super init];
    if (self == nil) return nil;
    _executable = [executable copy];
    _configDirectory = [configDirectory copy];
    _workingDirectory = [workingDirectory copy];
    _model = [model copy];
    _requestedSessionID = [sessionID copy];
    _lineBuffer = [NSMutableData data];
    _errorOutputBuffer = [NSMutableData data];
    _streamedText = [NSMutableString string];
    _parserQueue = dispatch_queue_create(
        "com.terminaldb.claude-code-stream", DISPATCH_QUEUE_SERIAL);
    return self;
}

- (void)streamPrompt:(NSString *)prompt
        systemPrompt:(NSString *)systemPrompt
           textDelta:(ClaudeAPITextDeltaBlock)textDelta
          completion:(ClaudeCodeCompletionBlock)completion {
    if (self.task != nil || self.finished) return;
    self.textDelta = textDelta;
    self.completion = completion;

    NSMutableArray<NSString *> *arguments = [NSMutableArray arrayWithArray:@[
        @"-p",
        @"--output-format", @"stream-json",
        @"--verbose",
        @"--include-partial-messages",
        @"--max-turns", @"1",
        @"--tools", @"",
        @"--disable-slash-commands",
        @"--strict-mcp-config",
    ]];
    if (self.model.length > 0) {
        [arguments addObjectsFromArray:@[@"--model", self.model]];
    }
    if (self.requestedSessionID.length > 0) {
        [arguments addObjectsFromArray:
            @[@"--resume", self.requestedSessionID]];
    } else {
        self.requestedSessionID = NSUUID.UUID.UUIDString;
        [arguments addObjectsFromArray:
            @[@"--session-id", self.requestedSessionID]];
        if (systemPrompt.length > 0) {
            [arguments addObjectsFromArray:
                @[@"--system-prompt", systemPrompt]];
        }
    }

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:self.executable];
    task.arguments = arguments;
    BOOL isDirectory = NO;
    if ([NSFileManager.defaultManager
            fileExistsAtPath:self.workingDirectory
                 isDirectory:&isDirectory] && isDirectory) {
        task.currentDirectoryURL =
            [NSURL fileURLWithPath:self.workingDirectory isDirectory:YES];
    }
    NSMutableDictionary *environment =
        [NSProcessInfo.processInfo.environment mutableCopy];
    for (NSString *key in @[
            @"ANTHROPIC_API_KEY",
            @"ANTHROPIC_AUTH_TOKEN",
            @"ANTHROPIC_BASE_URL",
            @"CLAUDE_CODE_OAUTH_TOKEN",
            @"CLAUDE_CODE_USE_BEDROCK",
            @"CLAUDE_CODE_USE_VERTEX",
            @"CLAUDE_CODE_USE_FOUNDRY",
        ]) {
        [environment removeObjectForKey:key];
    }
    environment[@"CLAUDE_CONFIG_DIR"] = self.configDirectory;
    task.environment = environment;
    self.inputPipe = [NSPipe pipe];
    self.outputPipe = [NSPipe pipe];
    self.errorPipe = [NSPipe pipe];
    task.standardInput = self.inputPipe;
    task.standardOutput = self.outputPipe;
    task.standardError = self.errorPipe;
    self.task = task;

    __weak typeof(self) weakSelf = self;
    self.outputPipe.fileHandleForReading.readabilityHandler =
        ^(NSFileHandle *handle) {
        NSData *data = handle.availableData;
        ClaudeCodeClient *strongSelf = weakSelf;
        if (strongSelf == nil || data.length == 0) return;
        dispatch_async(strongSelf.parserQueue, ^{
            [strongSelf consumeOutputData:data final:NO];
        });
    };
    self.errorPipe.fileHandleForReading.readabilityHandler =
        ^(NSFileHandle *handle) {
        NSData *data = handle.availableData;
        ClaudeCodeClient *strongSelf = weakSelf;
        if (strongSelf == nil || data.length == 0) return;
        dispatch_async(strongSelf.parserQueue, ^{
            [strongSelf appendErrorData:data];
        });
    };
    task.terminationHandler = ^(NSTask *completedTask) {
        ClaudeCodeClient *strongSelf = weakSelf;
        if (strongSelf == nil) return;
        strongSelf.outputPipe.fileHandleForReading.readabilityHandler = nil;
        strongSelf.errorPipe.fileHandleForReading.readabilityHandler = nil;
        NSData *remaining =
            [strongSelf.outputPipe.fileHandleForReading readDataToEndOfFile];
        NSData *errorData =
            [strongSelf.errorPipe.fileHandleForReading readDataToEndOfFile];
        dispatch_async(strongSelf.parserQueue, ^{
            if (remaining.length > 0) {
                [strongSelf consumeOutputData:remaining final:NO];
            }
            [strongSelf appendErrorData:errorData];
            [strongSelf consumeOutputData:[NSData data] final:YES];
            NSString *stderrText = [[NSString alloc]
                initWithData:strongSelf.errorOutputBuffer
                    encoding:NSUTF8StringEncoding];
            NSError *error = nil;
            if (completedTask.terminationStatus != 0 ||
                strongSelf.resultError.length > 0) {
                NSString *message = strongSelf.resultError;
                if (message.length == 0) {
                    message = [stderrText
                        stringByTrimmingCharactersInSet:
                            NSCharacterSet.whitespaceAndNewlineCharacterSet];
                }
                if (message.length > 1200) {
                    message = [message substringFromIndex:
                        message.length - 1200];
                }
                error = ClaudeError(completedTask.terminationStatus,
                    message.length > 0 ? message :
                    @"Claude Code could not complete the subscription request.");
            }
            [strongSelf finishWithError:error];
        });
    };

    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        self.outputPipe.fileHandleForReading.readabilityHandler = nil;
        self.errorPipe.fileHandleForReading.readabilityHandler = nil;
        [self.inputPipe.fileHandleForWriting closeFile];
        [self finishWithError:launchError];
    } else {
        NSData *promptData =
            [prompt dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
        @try {
            [self.inputPipe.fileHandleForWriting writeData:promptData];
        } @catch (NSException *exception) {
            [task terminate];
            [self finishWithError:ClaudeError(
                5, @"Claude Code closed its input before the request "
                   "could be sent.")];
        }
        [self.inputPipe.fileHandleForWriting closeFile];
    }
}

- (void)appendErrorData:(NSData *)data {
    if (data.length == 0) return;
    [self.errorOutputBuffer appendData:data];
    const NSUInteger limit = 64 * 1024;
    if (self.errorOutputBuffer.length > limit) {
        NSData *tail = [self.errorOutputBuffer subdataWithRange:
            NSMakeRange(self.errorOutputBuffer.length - limit, limit)];
        [self.errorOutputBuffer setData:tail];
    }
}

- (void)consumeOutputData:(NSData *)data final:(BOOL)final {
    if (self.finished) return;
    if (data.length > 0) [self.lineBuffer appendData:data];
    NSData *newline = [@"\n" dataUsingEncoding:NSUTF8StringEncoding];
    while (self.lineBuffer.length > 0) {
        NSRange range = [self.lineBuffer
            rangeOfData:newline
                options:0
                  range:NSMakeRange(0, self.lineBuffer.length)];
        if (range.location == NSNotFound && !final) return;
        NSUInteger length = range.location == NSNotFound
            ? self.lineBuffer.length : range.location;
        NSData *lineData =
            [self.lineBuffer subdataWithRange:NSMakeRange(0, length)];
        NSUInteger consumed = range.location == NSNotFound
            ? length : NSMaxRange(range);
        [self.lineBuffer replaceBytesInRange:NSMakeRange(0, consumed)
                                    withBytes:NULL
                                       length:0];
        NSString *line = [[NSString alloc]
            initWithData:lineData encoding:NSUTF8StringEncoding];
        [self processOutputLine:line];
    }
}

- (void)processOutputLine:(NSString *)line {
    NSString *trimmed = [line stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0) return;
    NSDictionary *event = [NSJSONSerialization
        JSONObjectWithData:[trimmed dataUsingEncoding:NSUTF8StringEncoding]
                   options:0 error:nil];
    if (![event isKindOfClass:NSDictionary.class]) return;

    NSString *sessionID =
        [event[@"session_id"] isKindOfClass:NSString.class]
            ? event[@"session_id"] : nil;
    if (sessionID.length > 0) self.returnedSessionID = sessionID;
    NSString *model =
        [event[@"model"] isKindOfClass:NSString.class]
            ? event[@"model"] : nil;
    if (model.length > 0) self.returnedModel = model;

    NSString *delta = [self.class textDeltaFromEvent:event];
    if (delta.length > 0) {
        [self.streamedText appendString:delta];
        ClaudeAPITextDeltaBlock callback = self.textDelta;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (callback != nil) callback(delta);
        });
    }
    if ([event[@"type"] isEqualToString:@"result"]) {
        if ([event[@"result"] isKindOfClass:NSString.class]) {
            self.resultText = event[@"result"];
        }
        if ([event[@"is_error"] boolValue]) {
            self.resultError = self.resultText;
        }
    }
}

- (void)cancel {
    @synchronized (self) {
        if (self.finished) return;
    }
    [self.task terminate];
    [self finishWithError:
        ClaudeError(NSUserCancelledError, @"Claude request cancelled.")];
}

- (void)finishWithError:(NSError *)error {
    @synchronized (self) {
        if (self.finished) return;
        self.finished = YES;
    }
    ClaudeCodeCompletionBlock completion = self.completion;
    NSString *text = self.resultText.length > 0
        ? self.resultText : [self.streamedText copy];
    NSString *sessionID =
        self.returnedSessionID ?: self.requestedSessionID;
    NSString *model = self.returnedModel;
    self.completion = nil;
    self.textDelta = nil;
    self.outputPipe.fileHandleForReading.readabilityHandler = nil;
    self.errorPipe.fileHandleForReading.readabilityHandler = nil;
    self.task = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (completion != nil) {
            completion(text ?: @"", sessionID, model, error);
        }
    });
}

@end

@implementation ClaudeAPIConfiguration

- (instancetype)init {
    self = [super init];
    if (self == nil) return nil;

    NSArray *saved =
        [NSUserDefaults.standardUserDefaults
            arrayForKey:ClaudeAPIModelsDefaultsKey];
    _models = ClaudeAPIValidModels(saved);
    _selectedModelID =
        [NSUserDefaults.standardUserDefaults
            stringForKey:ClaudeAPISelectedModelDefaultsKey];
    NSString *savedProvider = [NSUserDefaults.standardUserDefaults
        stringForKey:ClaudeAIProviderDefaultsKey];
    if (![savedProvider isEqualToString:ClaudeAIProviderSubscription] &&
        ![savedProvider isEqualToString:ClaudeAIProviderAPI]) {
        savedProvider = self.hasAPIKey
            ? ClaudeAIProviderAPI : ClaudeAIProviderSubscription;
    }
    _chatProvider = [savedProvider copy];
    NSString *subscriptionModel = [NSUserDefaults.standardUserDefaults
        stringForKey:ClaudeSubscriptionModelDefaultsKey] ?: @"";
    BOOL validSubscriptionModel = NO;
    for (NSDictionary *model in self.class.subscriptionModels) {
        if ([model[@"id"] isEqualToString:subscriptionModel]) {
            validSubscriptionModel = YES;
            break;
        }
    }
    _subscriptionModelID =
        validSubscriptionModel ? [subscriptionModel copy] : @"";
    return self;
}

+ (BOOL)runConfigurationSelfTests {
    NSArray *valid = ClaudeAPIValidModels(@[
        @"bad",
        @{@"id" : @7},
        @{@"display_name" : @"Missing ID"},
        @{@"id" : @"claude-test",
          @"display_name" : @"Test",
          @"created_at" : @123,
          @"unexpected" : @"discard"},
    ]);
    NSArray *subscriptionModels = self.subscriptionModels;
    BOOL subscriptionModelsValid =
        subscriptionModels.count == 4 &&
        [subscriptionModels.firstObject[@"id"] isEqualToString:@""] &&
        [subscriptionModels.lastObject[@"id"] isEqualToString:@"fable"];
    return valid.count == 1 &&
        [valid.firstObject[@"id"] isEqualToString:@"claude-test"] &&
        [valid.firstObject[@"display_name"] isEqualToString:@"Test"] &&
        valid.firstObject[@"created_at"] == nil &&
        valid.firstObject[@"unexpected"] == nil &&
        subscriptionModelsValid;
}

+ (NSArray<NSDictionary *> *)subscriptionModels {
    return @[
        @{@"id" : @"", @"display_name" : @"Default (recommended)"},
        @{@"id" : @"sonnet", @"display_name" : @"Sonnet"},
        @{@"id" : @"opus", @"display_name" : @"Opus"},
        @{@"id" : @"fable", @"display_name" : @"Fable"},
    ];
}

- (nullable NSString *)apiKey {
    return [NSUserDefaults.standardUserDefaults
        stringForKey:ClaudeAPIKeyDefaultsKey];
}

- (BOOL)hasAPIKey {
    return self.apiKey.length > 0;
}

- (BOOL)saveAPIKey:(NSString *)apiKey error:(NSError **)error {
    NSString *trimmed =
        [apiKey stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0) {
        if (error != NULL) {
            *error = ClaudeError(1, @"Enter an Anthropic API key.");
        }
        return NO;
    }

    [NSUserDefaults.standardUserDefaults
        setObject:trimmed forKey:ClaudeAPIKeyDefaultsKey];
    [self notifyChanged];
    return YES;
}

- (BOOL)removeAPIKeyWithError:(NSError **)error {
    (void)error;
    [NSUserDefaults.standardUserDefaults
        removeObjectForKey:ClaudeAPIKeyDefaultsKey];
    [NSUserDefaults.standardUserDefaults
        removeObjectForKey:ClaudeAPIModelsDefaultsKey];
    [NSUserDefaults.standardUserDefaults
        removeObjectForKey:ClaudeAPISelectedModelDefaultsKey];
    self.models = @[];
    self.selectedModelID = nil;
    [self notifyChanged];
    return YES;
}

- (void)selectChatProvider:(NSString *)provider {
    if (![provider isEqualToString:ClaudeAIProviderSubscription] &&
        ![provider isEqualToString:ClaudeAIProviderAPI]) {
        return;
    }
    if ([self.chatProvider isEqualToString:provider]) return;
    self.chatProvider = provider;
    [NSUserDefaults.standardUserDefaults
        setObject:provider forKey:ClaudeAIProviderDefaultsKey];
    [self notifyChanged];
}

- (void)selectModelID:(NSString *)modelID {
    if (modelID.length == 0 ||
        [self.selectedModelID isEqualToString:modelID]) {
        return;
    }
    self.selectedModelID = modelID;
    [NSUserDefaults.standardUserDefaults
        setObject:modelID forKey:ClaudeAPISelectedModelDefaultsKey];
    [self notifyChanged];
}

- (void)selectSubscriptionModelID:(NSString *)modelID {
    BOOL valid = NO;
    for (NSDictionary *model in self.class.subscriptionModels) {
        if ([model[@"id"] isEqualToString:modelID ?: @""]) {
            valid = YES;
            break;
        }
    }
    if (!valid ||
        [self.subscriptionModelID isEqualToString:modelID ?: @""]) {
        return;
    }
    self.subscriptionModelID = modelID ?: @"";
    [NSUserDefaults.standardUserDefaults
        setObject:self.subscriptionModelID
           forKey:ClaudeSubscriptionModelDefaultsKey];
    [self notifyChanged];
}

- (NSString *)displayNameForModelID:(NSString *)modelID {
    for (NSDictionary *model in self.models) {
        if (![model[@"id"] isEqualToString:modelID]) continue;
        NSString *displayName =
            [model[@"display_name"] isKindOfClass:NSString.class]
                ? model[@"display_name"]
                : nil;
        return displayName.length > 0 ? displayName : modelID;
    }
    return modelID;
}

- (NSString *)displayNameForSubscriptionModelID:(NSString *)modelID {
    for (NSDictionary *model in self.class.subscriptionModels) {
        if ([model[@"id"] isEqualToString:modelID ?: @""]) {
            return model[@"display_name"];
        }
    }
    return @"Default (recommended)";
}

- (void)refreshModelsWithCompletion:
    (void (^)(NSArray<NSDictionary *> *, NSError *_Nullable))completion {
    NSString *apiKey = self.apiKey;
    if (apiKey.length == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(@[], ClaudeError(2,
                @"Add an Anthropic API key before loading models."));
        });
        return;
    }

    NSURLComponents *components = [NSURLComponents
        componentsWithString:@"https://api.anthropic.com/v1/models"];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"limit" value:@"1000"],
    ];
    NSMutableURLRequest *request =
        [NSMutableURLRequest requestWithURL:components.URL];
    request.timeoutInterval = 20.0;
    [request setValue:apiKey forHTTPHeaderField:@"x-api-key"];
    [request setValue:ClaudeAPIVersion
        forHTTPHeaderField:@"anthropic-version"];
    [request setValue:@"TerminalDB/0.1" forHTTPHeaderField:@"User-Agent"];

    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task =
        [NSURLSession.sharedSession
            dataTaskWithRequest:request
              completionHandler:^(NSData *data,
                                  NSURLResponse *response,
                                  NSError *requestError) {
        NSHTTPURLResponse *http =
            [response isKindOfClass:NSHTTPURLResponse.class]
                ? (NSHTTPURLResponse *)response
                : nil;
        NSError *error = requestError;
        NSArray *models = nil;
        if (error == nil && http.statusCode != 200) {
            error = ClaudeError(http.statusCode,
                ClaudeAPIErrorMessage(data, http));
        }
        if (error == nil) {
            NSDictionary *json =
                [NSJSONSerialization JSONObjectWithData:data
                                                options:0
                                                  error:&error];
            NSArray *received =
                [json[@"data"] isKindOfClass:NSArray.class]
                    ? json[@"data"]
                    : nil;
            NSMutableArray *valid = [NSMutableArray array];
            for (NSDictionary *model in received) {
                if (![model isKindOfClass:NSDictionary.class]) continue;
                NSString *identifier =
                    [model[@"id"] isKindOfClass:NSString.class]
                        ? model[@"id"]
                        : nil;
                if (identifier.length == 0) continue;
                NSMutableDictionary *stored = [@{@"id" : identifier}
                    mutableCopy];
                for (NSString *key in
                        @[@"display_name", @"created_at", @"type"]) {
                    id value = model[key];
                    if ([value isKindOfClass:NSString.class]) {
                        stored[key] = value;
                    }
                }
                [valid addObject:stored];
            }
            models = valid;
            if (models.count == 0) {
                error = ClaudeError(3,
                    @"Anthropic returned no models for this API key.");
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            ClaudeAPIConfiguration *strongSelf = weakSelf;
            if (strongSelf != nil && error == nil) {
                strongSelf.models = models;
                [NSUserDefaults.standardUserDefaults
                    setObject:models forKey:ClaudeAPIModelsDefaultsKey];
                BOOL selectedStillExists = NO;
                for (NSDictionary *model in models) {
                    if ([model[@"id"]
                            isEqualToString:strongSelf.selectedModelID]) {
                        selectedStillExists = YES;
                        break;
                    }
                }
                if (!selectedStillExists) {
                    strongSelf.selectedModelID = models.firstObject[@"id"];
                    [NSUserDefaults.standardUserDefaults
                        setObject:strongSelf.selectedModelID
                           forKey:ClaudeAPISelectedModelDefaultsKey];
                }
                [strongSelf notifyChanged];
            }
            completion(models ?: @[], error);
        });
    }];
    [task resume];
}

- (void)notifyChanged {
    [NSNotificationCenter.defaultCenter
        postNotificationName:ClaudeAPIConfigurationDidChangeNotification
                      object:self];
}

@end

@interface ClaudeAPISettingsWindowController ()
@property(nonatomic, strong) ClaudeAPIConfiguration *configuration;
@property(nonatomic, strong, readwrite) NSView *panelView;
@property(nonatomic, weak, nullable) NSWindow *presentingWindow;
@property(nonatomic) BOOL panelPresented;
@property(nonatomic, strong) NSSegmentedControl *providerControl;
@property(nonatomic, strong) NSTextField *providerDetailLabel;
@property(nonatomic, strong) NSTextField *keyLabel;
@property(nonatomic, strong) NSSecureTextField *keyField;
@property(nonatomic, strong) NSTextField *keyStatusLabel;
@property(nonatomic, strong) NSPopUpButton *modelButton;
@property(nonatomic, strong) NSTextField *statusLabel;
@property(nonatomic, strong) NSButton *saveButton;
@property(nonatomic, strong) NSButton *removeButton;
@property(nonatomic, strong) NSProgressIndicator *progress;
@property(nonatomic, copy) NSString *subscriptionStatus;
@end

@implementation ClaudeAPISettingsWindowController

- (instancetype)initWithConfiguration:
    (ClaudeAPIConfiguration *)configuration {
    NSRect frame = NSMakeRect(0, 0, 620, 376);
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:frame
                  styleMask:NSWindowStyleMaskTitled |
                            NSWindowStyleMaskClosable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    self = [super initWithWindow:window];
    if (self == nil) return nil;

    _configuration = configuration;
    window.title = @"AI Chat Settings";
    window.releasedWhenClosed = NO;
    window.appearance =
        [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    [self buildContent];
    _panelView = window.contentView;
    [self reloadConfiguration];
    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(configurationDidChange:)
               name:ClaudeAPIConfigurationDidChangeNotification
             object:configuration];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (NSTextField *)labelWithString:(NSString *)string
                           frame:(NSRect)frame
                            font:(NSFont *)font {
    NSTextField *label = [[NSTextField alloc] initWithFrame:frame];
    label.stringValue = string;
    label.editable = NO;
    label.selectable = NO;
    label.bezeled = NO;
    label.drawsBackground = NO;
    label.font = font;
    label.textColor = NSColor.secondaryLabelColor;
    return label;
}

- (void)buildContent {
    NSView *content = self.window.contentView;
    NSTextField *title =
        [self labelWithString:@"Choose how TerminalDB talks to Claude"
                       frame:NSMakeRect(24, 328, 572, 24)
                        font:[NSFont systemFontOfSize:16
                                              weight:NSFontWeightSemibold]];
    title.textColor = NSColor.labelColor;
    [content addSubview:title];

    NSTextField *explanation =
        [self labelWithString:
            @"Use a signed-in Claude Code subscription or bill AI chat to an "
             "Anthropic API key. Your Claude accounts and usage tracking stay "
             "available with either choice."
                       frame:NSMakeRect(24, 286, 572, 38)
                        font:[NSFont systemFontOfSize:12]];
    explanation.maximumNumberOfLines = 2;
    explanation.lineBreakMode = NSLineBreakByWordWrapping;
    [content addSubview:explanation];

    NSTextField *providerLabel =
        [self labelWithString:@"AI provider"
                       frame:NSMakeRect(24, 248, 130, 20)
                        font:[NSFont systemFontOfSize:12
                                              weight:NSFontWeightMedium]];
    providerLabel.textColor = NSColor.labelColor;
    [content addSubview:providerLabel];

    self.providerControl =
        [[NSSegmentedControl alloc] initWithFrame:NSZeroRect];
    self.providerControl.segmentCount = 2;
    [self.providerControl setLabel:@"Claude Subscription" forSegment:0];
    [self.providerControl setLabel:@"Anthropic API" forSegment:1];
    self.providerControl.trackingMode =
        NSSegmentSwitchTrackingSelectOne;
    self.providerControl.target = self;
    self.providerControl.action = @selector(providerSelected:);
    self.providerControl.frame = NSMakeRect(154, 242, 442, 28);
    [content addSubview:self.providerControl];

    self.providerDetailLabel =
        [self labelWithString:@""
                       frame:NSMakeRect(154, 202, 442, 36)
                        font:[NSFont systemFontOfSize:11]];
    self.providerDetailLabel.maximumNumberOfLines = 2;
    self.providerDetailLabel.lineBreakMode = NSLineBreakByWordWrapping;
    [content addSubview:self.providerDetailLabel];

    NSTextField *modelLabel =
        [self labelWithString:@"Model"
                       frame:NSMakeRect(24, 169, 130, 20)
                        font:[NSFont systemFontOfSize:12
                                              weight:NSFontWeightMedium]];
    modelLabel.textColor = NSColor.labelColor;
    [content addSubview:modelLabel];

    self.modelButton =
        [[NSPopUpButton alloc] initWithFrame:NSMakeRect(154, 163, 442, 28)
                                  pullsDown:NO];
    self.modelButton.target = self;
    self.modelButton.action = @selector(modelSelected:);
    [content addSubview:self.modelButton];

    self.keyLabel =
        [self labelWithString:@"Anthropic API key"
                       frame:NSMakeRect(24, 121, 130, 20)
                        font:[NSFont systemFontOfSize:12
                                              weight:NSFontWeightMedium]];
    self.keyLabel.textColor = NSColor.labelColor;
    [content addSubview:self.keyLabel];

    self.keyField =
        [[NSSecureTextField alloc]
            initWithFrame:NSMakeRect(154, 115, 442, 26)];
    self.keyField.placeholderString = @"sk-ant-…";
    self.keyField.font =
        [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    self.keyField.usesSingleLineMode = YES;
    self.keyField.lineBreakMode = NSLineBreakByClipping;
    self.keyField.target = self;
    self.keyField.action = @selector(saveAndRefresh:);
    [content addSubview:self.keyField];

    self.keyStatusLabel =
        [self labelWithString:@""
                       frame:NSMakeRect(154, 93, 442, 18)
                        font:[NSFont systemFontOfSize:11]];
    [content addSubview:self.keyStatusLabel];

    self.statusLabel =
        [self labelWithString:@""
                       frame:NSMakeRect(24, 62, 520, 24)
                        font:[NSFont systemFontOfSize:11]];
    [content addSubview:self.statusLabel];

    self.progress = [[NSProgressIndicator alloc]
        initWithFrame:NSMakeRect(578, 66, 16, 16)];
    self.progress.style = NSProgressIndicatorStyleSpinning;
    self.progress.controlSize = NSControlSizeSmall;
    self.progress.displayedWhenStopped = NO;
    [content addSubview:self.progress];

    self.removeButton =
        [[NSButton alloc] initWithFrame:NSMakeRect(24, 20, 104, 32)];
    self.removeButton.title = @"Remove Key";
    self.removeButton.bezelStyle = NSBezelStyleRounded;
    self.removeButton.target = self;
    self.removeButton.action = @selector(removeKey:);
    [content addSubview:self.removeButton];

    self.saveButton =
        [[NSButton alloc] initWithFrame:NSMakeRect(386, 20, 146, 32)];
    self.saveButton.title = @"Save & Refresh";
    self.saveButton.bezelStyle = NSBezelStyleRounded;
    self.saveButton.target = self;
    self.saveButton.action = @selector(saveAndRefresh:);
    [content addSubview:self.saveButton];

    NSButton *done = [[NSButton alloc]
        initWithFrame:NSMakeRect(538, 20, 58, 32)];
    done.title = @"Done";
    done.bezelStyle = NSBezelStyleRounded;
    done.keyEquivalent = @"\r";
    done.target = self;
    done.action = @selector(done:);
    [content addSubview:done];
}

- (void)presentWithSubscriptionStatus:(NSString *)status {
    self.panelPresented = NO;
    self.subscriptionStatus = status ?: @"No Claude Code account is selected.";
    [self reloadConfiguration];
    [self showWindow:nil];
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    if ([self.configuration.chatProvider
            isEqualToString:ClaudeAIProviderAPI] &&
        self.keyField.stringValue.length > 0) {
        [self refreshModels];
    } else if ([self.configuration.chatProvider
                   isEqualToString:ClaudeAIProviderAPI]) {
        [self.window makeFirstResponder:self.keyField];
    }
}

- (void)prepareWithSubscriptionStatus:(NSString *)status
                               inWindow:(NSWindow *)window {
    self.subscriptionStatus = status ?: @"No Claude Code account is selected.";
    self.presentingWindow = window;
    self.panelPresented = YES;
    if (self.window.contentView == self.panelView) {
        self.window.contentView = [[NSView alloc]
            initWithFrame:self.panelView.frame];
    }
    [self reloadConfiguration];
    if ([self.configuration.chatProvider
            isEqualToString:ClaudeAIProviderAPI] &&
        self.keyField.stringValue.length > 0) {
        [self refreshModels];
    } else if ([self.configuration.chatProvider
                   isEqualToString:ClaudeAIProviderAPI]) {
        [window makeFirstResponder:self.keyField];
    }
}

- (void)didDismissPanel {
    self.panelPresented = NO;
    self.presentingWindow = nil;
}

- (NSWindow *)presentationWindow {
    return self.presentingWindow ?: self.window;
}

- (void)configurationDidChange:(NSNotification *)notification {
    (void)notification;
    [self reloadConfiguration];
}

- (void)reloadConfiguration {
    BOOL usesAPI = [self.configuration.chatProvider
        isEqualToString:ClaudeAIProviderAPI];
    self.providerControl.selectedSegment = usesAPI ? 1 : 0;
    self.keyLabel.hidden = !usesAPI;
    self.keyField.hidden = !usesAPI;
    self.keyStatusLabel.hidden = !usesAPI;
    self.removeButton.hidden = !usesAPI;
    self.saveButton.hidden = !usesAPI;

    NSString *storedKey = self.configuration.apiKey;
    BOOL hasKey = storedKey.length > 0;
    self.keyField.stringValue = storedKey ?: @"";
    self.keyStatusLabel.stringValue = hasKey
        ? @"Saved in TerminalDB preferences. Edit and save to replace it."
        : @"No API key is stored.";
    self.removeButton.enabled = hasKey;

    self.providerDetailLabel.stringValue = usesAPI
        ? @"AI chat is sent directly to Anthropic and billed to this API "
           "key. Claude Code accounts and usage remain available."
        : [NSString stringWithFormat:
            @"AI chat uses the Claude Code subscription selected for this "
             "terminal tab. %@",
            self.subscriptionStatus ?: @"Choose an account from the Claude menu."];

    [self.modelButton removeAllItems];
    if (!usesAPI) {
        NSArray<NSDictionary *> *models =
            ClaudeAPIConfiguration.subscriptionModels;
        NSInteger selectedIndex = 0;
        for (NSUInteger index = 0; index < models.count; index++) {
            NSDictionary *model = models[index];
            [self.modelButton addItemWithTitle:model[@"display_name"]];
            self.modelButton.lastItem.representedObject = model[@"id"];
            if ([model[@"id"] isEqualToString:
                    self.configuration.subscriptionModelID]) {
                selectedIndex = (NSInteger)index;
            }
        }
        [self.modelButton selectItemAtIndex:selectedIndex];
        self.modelButton.enabled = YES;
        self.statusLabel.stringValue =
            @"Changing provider or model starts a new chat.";
        self.statusLabel.textColor = NSColor.secondaryLabelColor;
        return;
    }

    if (self.configuration.models.count == 0) {
        [self.modelButton addItemWithTitle:
            hasKey ? @"Refresh to load models" : @"Add a key to load models"];
        self.modelButton.enabled = NO;
        self.statusLabel.stringValue = hasKey
            ? @"Save & Refresh to load the models available to this key."
            : @"Add a key to use the Anthropic API provider.";
        self.statusLabel.textColor = NSColor.secondaryLabelColor;
        return;
    }

    self.modelButton.enabled = YES;
    NSInteger selectedIndex = 0;
    for (NSUInteger index = 0;
         index < self.configuration.models.count;
         index++) {
        NSDictionary *model = self.configuration.models[index];
        NSString *identifier = model[@"id"];
        NSString *displayName =
            [model[@"display_name"] isKindOfClass:NSString.class]
                ? model[@"display_name"]
                : identifier;
        NSString *title = [displayName isEqualToString:identifier]
            ? identifier
            : [NSString stringWithFormat:@"%@  —  %@", displayName, identifier];
        [self.modelButton addItemWithTitle:title];
        self.modelButton.lastItem.representedObject = identifier;
        if ([identifier
                isEqualToString:self.configuration.selectedModelID]) {
            selectedIndex = (NSInteger)index;
        }
    }
    [self.modelButton selectItemAtIndex:selectedIndex];
    self.statusLabel.stringValue =
        @"Available models come directly from Anthropic.";
    self.statusLabel.textColor = NSColor.secondaryLabelColor;
}

- (void)providerSelected:(id)sender {
    (void)sender;
    NSString *provider = self.providerControl.selectedSegment == 1
        ? ClaudeAIProviderAPI : ClaudeAIProviderSubscription;
    [self.configuration selectChatProvider:provider];
    [self reloadConfiguration];
    if ([provider isEqualToString:ClaudeAIProviderAPI] &&
        !self.configuration.hasAPIKey) {
        [[self presentationWindow] makeFirstResponder:self.keyField];
    }
}

- (void)saveAndRefresh:(id)sender {
    (void)sender;
    NSString *candidate = self.keyField.stringValue;
    if (candidate.length > 0) {
        NSError *error = nil;
        if (![self.configuration saveAPIKey:candidate error:&error]) {
            self.statusLabel.stringValue = error.localizedDescription;
            self.statusLabel.textColor = NSColor.systemRedColor;
            return;
        }
    }
    if (!self.configuration.hasAPIKey) {
        self.statusLabel.stringValue = @"Enter an Anthropic API key first.";
        self.statusLabel.textColor = NSColor.systemRedColor;
        [[self presentationWindow] makeFirstResponder:self.keyField];
        return;
    }
    [self refreshModels];
}

- (void)refreshModels {
    self.saveButton.enabled = NO;
    self.modelButton.enabled = NO;
    self.statusLabel.stringValue = @"Loading available models…";
    self.statusLabel.textColor = NSColor.secondaryLabelColor;
    [self.progress startAnimation:nil];
    __weak typeof(self) weakSelf = self;
    [self.configuration
        refreshModelsWithCompletion:^(NSArray<NSDictionary *> *models,
                                      NSError *error) {
        ClaudeAPISettingsWindowController *strongSelf = weakSelf;
        if (strongSelf == nil) return;
        strongSelf.saveButton.enabled = YES;
        [strongSelf.progress stopAnimation:nil];
        [strongSelf reloadConfiguration];
        if (error != nil) {
            strongSelf.statusLabel.stringValue = error.localizedDescription;
            strongSelf.statusLabel.textColor = NSColor.systemRedColor;
        } else {
            strongSelf.statusLabel.stringValue =
                [NSString stringWithFormat:
                    @"Loaded %lu model%@ from Anthropic.",
                    (unsigned long)models.count,
                    models.count == 1 ? @"" : @"s"];
            strongSelf.statusLabel.textColor = NSColor.secondaryLabelColor;
        }
    }];
}

- (void)modelSelected:(id)sender {
    (void)sender;
    NSString *identifier =
        [self.modelButton.selectedItem.representedObject
            isKindOfClass:NSString.class]
            ? self.modelButton.selectedItem.representedObject
            : nil;
    if (identifier.length > 0) {
        if ([self.configuration.chatProvider
                isEqualToString:ClaudeAIProviderAPI]) {
            [self.configuration selectModelID:identifier];
        } else {
            [self.configuration selectSubscriptionModelID:identifier];
        }
        self.statusLabel.stringValue =
            @"This model will be used for new AI chats.";
        self.statusLabel.textColor = NSColor.secondaryLabelColor;
    } else if ([self.configuration.chatProvider
                   isEqualToString:ClaudeAIProviderSubscription]) {
        [self.configuration selectSubscriptionModelID:@""];
        self.statusLabel.stringValue =
            @"Claude Code will choose the account’s default model.";
        self.statusLabel.textColor = NSColor.secondaryLabelColor;
    }
}

- (void)removeKey:(id)sender {
    (void)sender;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Remove the Claude API key?";
    alert.informativeText =
        @"The API provider will be unavailable until another key is added. "
         "Claude subscription accounts are not changed.";
    [alert addButtonWithTitle:@"Remove Key"];
    [alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;

    NSError *error = nil;
    if (![self.configuration removeAPIKeyWithError:&error]) {
        self.statusLabel.stringValue = error.localizedDescription;
        self.statusLabel.textColor = NSColor.systemRedColor;
        return;
    }
    if ([self.configuration.chatProvider
            isEqualToString:ClaudeAIProviderAPI]) {
        [self.configuration
            selectChatProvider:ClaudeAIProviderSubscription];
    }
    self.statusLabel.stringValue =
        @"The API key was removed from TerminalDB preferences.";
    self.statusLabel.textColor = NSColor.secondaryLabelColor;
    [self reloadConfiguration];
}

- (void)done:(id)sender {
    (void)sender;
    if (self.panelPresented && self.dismissHandler != nil) {
        self.dismissHandler();
    } else {
        [self.window orderOut:nil];
    }
}

@end

@interface ClaudeAPIClient ()
@property(nonatomic, copy) NSString *apiKey;
@property(nonatomic, copy) NSString *model;
@property(nonatomic, strong, nullable) NSURLSession *session;
@property(nonatomic, strong, nullable) NSURLSessionDataTask *task;
@property(nonatomic, strong) NSMutableData *streamBuffer;
@property(nonatomic, strong) NSMutableData *errorBuffer;
@property(nonatomic, strong, nullable) NSHTTPURLResponse *response;
@property(nonatomic, copy, nullable) ClaudeAPITextDeltaBlock textDelta;
@property(nonatomic, copy, nullable) ClaudeAPICompletionBlock completion;
@property(nonatomic, strong)
    NSMutableDictionary<NSNumber *, NSMutableDictionary *> *contentBlocks;
@property(nonatomic, copy, nullable) NSString *stopReason;
@property(nonatomic) BOOL finished;
@end

@implementation ClaudeAPIClient

- (instancetype)initWithAPIKey:(NSString *)apiKey
                         model:(NSString *)model {
    self = [super init];
    if (self == nil) return nil;
    _apiKey = [apiKey copy];
    _model = [model copy];
    _streamBuffer = [NSMutableData data];
    _errorBuffer = [NSMutableData data];
    _contentBlocks = [NSMutableDictionary dictionary];
    return self;
}

- (void)streamMessages:(NSArray<NSDictionary *> *)messages
                 system:(NSString *)system
                  tools:(NSArray<NSDictionary *> *)tools
              textDelta:(ClaudeAPITextDeltaBlock)textDelta
             completion:(ClaudeAPICompletionBlock)completion {
    self.textDelta = textDelta;
    self.completion = completion;

    NSMutableDictionary *body = [@{
        @"model" : self.model,
        @"max_tokens" : @4096,
        @"stream" : @YES,
        @"system" : system,
        @"messages" : messages,
    } mutableCopy];
    if (tools.count > 0) {
        body[@"tools"] = tools;
        body[@"tool_choice"] = @{
            @"type" : @"auto",
            @"disable_parallel_tool_use" : @YES,
        };
    }
    NSError *jsonError = nil;
    NSData *bodyData =
        [NSJSONSerialization dataWithJSONObject:body
                                         options:0
                                           error:&jsonError];
    if (bodyData == nil) {
        [self finishWithError:jsonError];
        return;
    }

    NSMutableURLRequest *request =
        [NSMutableURLRequest requestWithURL:
            [NSURL URLWithString:@"https://api.anthropic.com/v1/messages"]];
    request.HTTPMethod = @"POST";
    request.HTTPBody = bodyData;
    request.timeoutInterval = 120.0;
    [request setValue:@"application/json"
        forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"text/event-stream"
        forHTTPHeaderField:@"Accept"];
    [request setValue:self.apiKey forHTTPHeaderField:@"x-api-key"];
    [request setValue:ClaudeAPIVersion
        forHTTPHeaderField:@"anthropic-version"];
    [request setValue:@"TerminalDB/0.1" forHTTPHeaderField:@"User-Agent"];

    NSOperationQueue *queue = [[NSOperationQueue alloc] init];
    queue.maxConcurrentOperationCount = 1;
    queue.qualityOfService = NSQualityOfServiceUserInitiated;
    self.session =
        [NSURLSession sessionWithConfiguration:
            NSURLSessionConfiguration.ephemeralSessionConfiguration
                                  delegate:self
                             delegateQueue:queue];
    self.task = [self.session dataTaskWithRequest:request];
    [self.task resume];
}

- (void)cancel {
    if (self.finished) return;
    [self.task cancel];
    [self finishWithError:ClaudeError(NSUserCancelledError,
                                      @"Claude request cancelled.")];
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    (void)session;
    (void)dataTask;
    self.response = [response isKindOfClass:NSHTTPURLResponse.class]
        ? (NSHTTPURLResponse *)response
        : nil;
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
    (void)session;
    (void)dataTask;
    if (self.finished) return;
    if (self.response.statusCode != 200) {
        [self.errorBuffer appendData:data];
        return;
    }
    [self.streamBuffer appendData:data];
    [self processAvailableEvents];
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    (void)session;
    (void)task;
    if (self.finished) return;
    if (error != nil) {
        [self finishWithError:error];
        return;
    }
    if (self.response.statusCode != 200) {
        [self finishWithError:ClaudeError(self.response.statusCode,
            ClaudeAPIErrorMessage(self.errorBuffer, self.response))];
        return;
    }
    [self processAvailableEvents];
    if (!self.finished && self.streamBuffer.length > 0) {
        NSString *finalEvent = [[NSString alloc]
            initWithData:self.streamBuffer encoding:NSUTF8StringEncoding];
        [self.streamBuffer setLength:0];
        if ([finalEvent
                stringByTrimmingCharactersInSet:
                    NSCharacterSet.whitespaceAndNewlineCharacterSet].length >
            0) {
            [self processEvent:finalEvent];
        }
    }
    [self finishWithError:nil];
}

- (void)processAvailableEvents {
    NSData *doubleLF = [@"\n\n" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *doubleCRLF =
        [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
    while (self.streamBuffer.length > 0) {
        NSRange full = NSMakeRange(0, self.streamBuffer.length);
        NSRange lf =
            [self.streamBuffer rangeOfData:doubleLF options:0 range:full];
        NSRange crlf =
            [self.streamBuffer rangeOfData:doubleCRLF options:0 range:full];
        NSRange separator = NSMakeRange(NSNotFound, 0);
        if (lf.location != NSNotFound) separator = lf;
        if (crlf.location != NSNotFound &&
            (separator.location == NSNotFound ||
             crlf.location < separator.location)) {
            separator = crlf;
        }
        if (separator.location == NSNotFound) return;

        NSData *eventData =
            [self.streamBuffer subdataWithRange:
                NSMakeRange(0, separator.location)];
        NSUInteger consumed = NSMaxRange(separator);
        [self.streamBuffer replaceBytesInRange:NSMakeRange(0, consumed)
                                      withBytes:NULL
                                         length:0];
        NSString *event = [[NSString alloc]
            initWithData:eventData encoding:NSUTF8StringEncoding];
        if (event.length > 0) [self processEvent:event];
        if (self.finished) return;
    }
}

- (void)processEvent:(NSString *)event {
    NSMutableArray<NSString *> *dataLines = [NSMutableArray array];
    for (NSString *rawLine in
            [event componentsSeparatedByCharactersInSet:
                NSCharacterSet.newlineCharacterSet]) {
        NSString *line =
            [rawLine stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (![line hasPrefix:@"data:"]) continue;
        NSString *value = [line substringFromIndex:5];
        if ([value hasPrefix:@" "]) value = [value substringFromIndex:1];
        [dataLines addObject:value];
    }
    if (dataLines.count == 0) return;

    NSData *jsonData =
        [[dataLines componentsJoinedByString:@"\n"]
            dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *json =
        [NSJSONSerialization JSONObjectWithData:jsonData
                                        options:0
                                          error:nil];
    NSString *type =
        [json[@"type"] isKindOfClass:NSString.class] ? json[@"type"] : nil;
    if ([type isEqualToString:@"content_block_start"]) {
        NSNumber *index =
            [json[@"index"] isKindOfClass:NSNumber.class] ? json[@"index"] : nil;
        NSDictionary *contentBlock =
            [json[@"content_block"] isKindOfClass:NSDictionary.class]
                ? json[@"content_block"]
                : nil;
        NSString *blockType =
            [contentBlock[@"type"] isKindOfClass:NSString.class]
                ? contentBlock[@"type"]
                : nil;
        if (index != nil && [blockType isEqualToString:@"text"]) {
            NSString *text =
                [contentBlock[@"text"] isKindOfClass:NSString.class]
                    ? contentBlock[@"text"]
                    : @"";
            self.contentBlocks[index] = [@{
                @"type" : @"text",
                @"text" : [text mutableCopy],
            } mutableCopy];
        } else if (index != nil &&
                   [blockType isEqualToString:@"tool_use"]) {
            NSString *identifier =
                [contentBlock[@"id"] isKindOfClass:NSString.class]
                    ? contentBlock[@"id"]
                    : @"";
            NSString *name =
                [contentBlock[@"name"] isKindOfClass:NSString.class]
                    ? contentBlock[@"name"]
                    : @"";
            self.contentBlocks[index] = [@{
                @"type" : @"tool_use",
                @"id" : identifier,
                @"name" : name,
                @"input" : @{},
                @"_partial_json" : [NSMutableString string],
            } mutableCopy];
        }
    } else if ([type isEqualToString:@"content_block_delta"]) {
        NSNumber *index =
            [json[@"index"] isKindOfClass:NSNumber.class] ? json[@"index"] : nil;
        NSDictionary *delta =
            [json[@"delta"] isKindOfClass:NSDictionary.class]
                ? json[@"delta"]
                : nil;
        if ([delta[@"type"] isEqualToString:@"text_delta"] &&
            [delta[@"text"] isKindOfClass:NSString.class]) {
            NSString *text = [delta[@"text"] copy];
            NSMutableDictionary *block =
                index != nil ? self.contentBlocks[index] : nil;
            NSMutableString *fullText =
                [block[@"text"] isKindOfClass:NSMutableString.class]
                    ? block[@"text"]
                    : nil;
            [fullText appendString:text];
            ClaudeAPITextDeltaBlock textDelta = self.textDelta;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (textDelta != nil) textDelta(text);
            });
        } else if ([delta[@"type"] isEqualToString:@"input_json_delta"] &&
                   [delta[@"partial_json"] isKindOfClass:NSString.class]) {
            NSMutableDictionary *block =
                index != nil ? self.contentBlocks[index] : nil;
            NSMutableString *partial =
                [block[@"_partial_json"]
                    isKindOfClass:NSMutableString.class]
                    ? block[@"_partial_json"]
                    : nil;
            [partial appendString:delta[@"partial_json"]];
        }
    } else if ([type isEqualToString:@"content_block_stop"]) {
        NSNumber *index =
            [json[@"index"] isKindOfClass:NSNumber.class] ? json[@"index"] : nil;
        NSMutableDictionary *block =
            index != nil ? self.contentBlocks[index] : nil;
        if ([block[@"type"] isEqualToString:@"tool_use"]) {
            NSString *partial =
                [block[@"_partial_json"] isKindOfClass:NSString.class]
                    ? block[@"_partial_json"]
                    : @"";
            if (partial.length > 0) {
                NSData *inputData =
                    [partial dataUsingEncoding:NSUTF8StringEncoding];
                id input =
                    [NSJSONSerialization JSONObjectWithData:inputData
                                                    options:0
                                                      error:nil];
                if ([input isKindOfClass:NSDictionary.class]) {
                    block[@"input"] = input;
                }
            }
            [block removeObjectForKey:@"_partial_json"];
        }
    } else if ([type isEqualToString:@"message_delta"]) {
        NSDictionary *delta =
            [json[@"delta"] isKindOfClass:NSDictionary.class]
                ? json[@"delta"]
                : nil;
        if ([delta[@"stop_reason"] isKindOfClass:NSString.class]) {
            self.stopReason = delta[@"stop_reason"];
        }
    } else if ([type isEqualToString:@"error"]) {
        NSDictionary *apiError =
            [json[@"error"] isKindOfClass:NSDictionary.class]
                ? json[@"error"]
                : nil;
        NSString *message =
            [apiError[@"message"] isKindOfClass:NSString.class]
                ? apiError[@"message"]
                : @"Claude stream failed.";
        [self finishWithError:ClaudeError(4, message)];
    } else if ([type isEqualToString:@"message_stop"]) {
        [self finishWithError:nil];
    }
}

- (NSArray<NSDictionary *> *)completedContentBlocks {
    NSArray<NSNumber *> *indexes = [self.contentBlocks.allKeys
        sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray<NSDictionary *> *blocks = [NSMutableArray array];
    for (NSNumber *index in indexes) {
        NSMutableDictionary *stored = self.contentBlocks[index];
        NSMutableDictionary *block = [stored mutableCopy];
        [block removeObjectForKey:@"_partial_json"];
        if ([block[@"text"] isKindOfClass:NSMutableString.class]) {
            block[@"text"] = [block[@"text"] copy];
        }
        [blocks addObject:[block copy]];
    }
    return blocks;
}

- (void)finishWithError:(NSError *)error {
    @synchronized (self) {
        if (self.finished) return;
        self.finished = YES;
    }
    ClaudeAPICompletionBlock completion = self.completion;
    NSArray<NSDictionary *> *contentBlocks = [self completedContentBlocks];
    NSString *stopReason = self.stopReason;
    self.completion = nil;
    self.textDelta = nil;
    [self.task cancel];
    [self.session finishTasksAndInvalidate];
    self.task = nil;
    self.session = nil;
    self.apiKey = @"";
    dispatch_async(dispatch_get_main_queue(), ^{
        if (completion != nil) {
            completion(contentBlocks, stopReason, error);
        }
    });
}

@end
