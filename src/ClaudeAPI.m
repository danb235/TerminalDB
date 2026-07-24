#import "ClaudeAPI.h"

NSNotificationName const ClaudeAPIConfigurationDidChangeNotification =
    @"ClaudeAPIConfigurationDidChangeNotification";

static NSString *const ClaudeAPIKeyDefaultsKey = @"ClaudeAPIKey";
static NSString *const ClaudeAPISelectedModelDefaultsKey =
    @"ClaudeAPISelectedModel";
static NSString *const ClaudeAPIModelsDefaultsKey = @"ClaudeAPIModels";
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

@interface ClaudeAPIConfiguration ()
@property(nonatomic, copy) NSArray<NSDictionary *> *models;
@property(nonatomic, copy, nullable) NSString *selectedModelID;
@end

@implementation ClaudeAPIConfiguration

- (instancetype)init {
    self = [super init];
    if (self == nil) return nil;

    NSArray *saved =
        [NSUserDefaults.standardUserDefaults
            arrayForKey:ClaudeAPIModelsDefaultsKey];
    NSMutableArray<NSDictionary *> *valid = [NSMutableArray array];
    for (NSDictionary *model in saved) {
        NSString *identifier =
            [model[@"id"] isKindOfClass:NSString.class] ? model[@"id"] : nil;
        if (identifier.length > 0) [valid addObject:model];
    }
    _models = valid;
    _selectedModelID =
        [NSUserDefaults.standardUserDefaults
            stringForKey:ClaudeAPISelectedModelDefaultsKey];
    return self;
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
    [self notifyChanged];
    return YES;
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
@property(nonatomic, strong) NSTextField *keyField;
@property(nonatomic, strong) NSTextField *keyStatusLabel;
@property(nonatomic, strong) NSPopUpButton *modelButton;
@property(nonatomic, strong) NSTextField *statusLabel;
@property(nonatomic, strong) NSButton *saveButton;
@property(nonatomic, strong) NSButton *removeButton;
@property(nonatomic, strong) NSProgressIndicator *progress;
@end

@implementation ClaudeAPISettingsWindowController

- (instancetype)initWithConfiguration:
    (ClaudeAPIConfiguration *)configuration {
    NSRect frame = NSMakeRect(0, 0, 520, 286);
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:frame
                  styleMask:NSWindowStyleMaskTitled |
                            NSWindowStyleMaskClosable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    self = [super initWithWindow:window];
    if (self == nil) return nil;

    _configuration = configuration;
    window.title = @"Claude API Settings";
    window.releasedWhenClosed = NO;
    window.appearance =
        [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    [self buildContent];
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
        [self labelWithString:@"Natural-language terminal assistant"
                       frame:NSMakeRect(24, 238, 472, 24)
                        font:[NSFont systemFontOfSize:16
                                              weight:NSFontWeightSemibold]];
    title.textColor = NSColor.labelColor;
    [content addSubview:title];

    NSTextField *explanation =
        [self labelWithString:
            @"The API key is saved in this Mac’s TerminalDB preferences. "
             "It is never added to the project."
                       frame:NSMakeRect(24, 204, 472, 34)
                        font:[NSFont systemFontOfSize:12]];
    explanation.maximumNumberOfLines = 2;
    explanation.lineBreakMode = NSLineBreakByWordWrapping;
    [content addSubview:explanation];

    NSTextField *keyLabel =
        [self labelWithString:@"Anthropic API key"
                       frame:NSMakeRect(24, 170, 130, 20)
                        font:[NSFont systemFontOfSize:12
                                              weight:NSFontWeightMedium]];
    keyLabel.textColor = NSColor.labelColor;
    [content addSubview:keyLabel];

    self.keyField =
        [[NSTextField alloc] initWithFrame:NSMakeRect(154, 164, 342, 26)];
    self.keyField.placeholderString = @"sk-ant-…";
    self.keyField.font =
        [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    self.keyField.target = self;
    self.keyField.action = @selector(saveAndRefresh:);
    [content addSubview:self.keyField];

    self.keyStatusLabel =
        [self labelWithString:@""
                       frame:NSMakeRect(154, 142, 342, 18)
                        font:[NSFont systemFontOfSize:11]];
    [content addSubview:self.keyStatusLabel];

    NSTextField *modelLabel =
        [self labelWithString:@"Model"
                       frame:NSMakeRect(24, 108, 130, 20)
                        font:[NSFont systemFontOfSize:12
                                              weight:NSFontWeightMedium]];
    modelLabel.textColor = NSColor.labelColor;
    [content addSubview:modelLabel];

    self.modelButton =
        [[NSPopUpButton alloc] initWithFrame:NSMakeRect(154, 102, 342, 28)
                                  pullsDown:NO];
    self.modelButton.target = self;
    self.modelButton.action = @selector(modelSelected:);
    [content addSubview:self.modelButton];

    self.statusLabel =
        [self labelWithString:
            @"Available models refresh automatically from Anthropic."
                       frame:NSMakeRect(24, 66, 390, 24)
                        font:[NSFont systemFontOfSize:11]];
    [content addSubview:self.statusLabel];

    self.progress = [[NSProgressIndicator alloc]
        initWithFrame:NSMakeRect(478, 70, 16, 16)];
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
        [[NSButton alloc] initWithFrame:NSMakeRect(286, 20, 146, 32)];
    self.saveButton.title = @"Save & Refresh";
    self.saveButton.bezelStyle = NSBezelStyleRounded;
    self.saveButton.target = self;
    self.saveButton.action = @selector(saveAndRefresh:);
    [content addSubview:self.saveButton];

    NSButton *done = [[NSButton alloc]
        initWithFrame:NSMakeRect(438, 20, 58, 32)];
    done.title = @"Done";
    done.bezelStyle = NSBezelStyleRounded;
    done.keyEquivalent = @"\r";
    done.target = self;
    done.action = @selector(done:);
    [content addSubview:done];
}

- (void)present {
    [self reloadConfiguration];
    [self showWindow:nil];
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    if (self.keyField.stringValue.length > 0) {
        [self refreshModels];
    } else {
        [self.window makeFirstResponder:self.keyField];
    }
}

- (void)configurationDidChange:(NSNotification *)notification {
    (void)notification;
    [self reloadConfiguration];
}

- (void)reloadConfiguration {
    NSString *storedKey = self.configuration.apiKey;
    BOOL hasKey = storedKey.length > 0;
    self.keyField.stringValue = storedKey ?: @"";
    self.keyStatusLabel.stringValue = hasKey
        ? @"Saved in TerminalDB preferences. Edit and save to replace it."
        : @"No API key is stored.";
    self.removeButton.enabled = hasKey;

    [self.modelButton removeAllItems];
    if (self.configuration.models.count == 0) {
        [self.modelButton addItemWithTitle:
            hasKey ? @"Refresh to load models" : @"Add a key to load models"];
        self.modelButton.enabled = NO;
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
        [self.window makeFirstResponder:self.keyField];
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
        [self.configuration selectModelID:identifier];
        self.statusLabel.stringValue =
            @"This model will be used for new AI chats.";
        self.statusLabel.textColor = NSColor.secondaryLabelColor;
    }
}

- (void)removeKey:(id)sender {
    (void)sender;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Remove the Claude API key?";
    alert.informativeText =
        @"TerminalDB will stop sending AI chat requests until "
         "another key is added.";
    [alert addButtonWithTitle:@"Remove Key"];
    [alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;

    NSError *error = nil;
    if (![self.configuration removeAPIKeyWithError:&error]) {
        self.statusLabel.stringValue = error.localizedDescription;
        self.statusLabel.textColor = NSColor.systemRedColor;
        return;
    }
    self.statusLabel.stringValue =
        @"The API key was removed from TerminalDB preferences.";
    self.statusLabel.textColor = NSColor.secondaryLabelColor;
    [self reloadConfiguration];
}

- (void)done:(id)sender {
    (void)sender;
    [self.window orderOut:nil];
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
