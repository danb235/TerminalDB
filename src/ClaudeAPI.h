#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const ClaudeAPIConfigurationDidChangeNotification;
extern NSString *const ClaudeAIProviderSubscription;
extern NSString *const ClaudeAIProviderAPI;

@interface ClaudeAPIConfiguration : NSObject

@property(nonatomic, readonly) BOOL hasAPIKey;
@property(nonatomic, copy, readonly) NSArray<NSDictionary *> *models;
@property(nonatomic, copy, readonly, nullable) NSString *selectedModelID;
@property(nonatomic, copy, readonly) NSString *chatProvider;
@property(nonatomic, copy, readonly) NSString *subscriptionModelID;

+ (BOOL)runConfigurationSelfTests;
+ (NSArray<NSDictionary *> *)subscriptionModels;
- (nullable NSString *)apiKey;
- (BOOL)saveAPIKey:(NSString *)apiKey error:(NSError **)error;
- (BOOL)removeAPIKeyWithError:(NSError **)error;
- (void)selectChatProvider:(NSString *)provider;
- (void)selectModelID:(NSString *)modelID;
- (void)selectSubscriptionModelID:(NSString *)modelID;
- (NSString *)displayNameForModelID:(NSString *)modelID;
- (NSString *)displayNameForSubscriptionModelID:(NSString *)modelID;
- (void)refreshModelsWithCompletion:
    (void (^)(NSArray<NSDictionary *> *models, NSError *_Nullable error))completion;

@end

@interface ClaudeAPISettingsWindowController : NSWindowController

- (instancetype)initWithConfiguration:
    (ClaudeAPIConfiguration *)configuration;
- (void)presentWithSubscriptionStatus:(nullable NSString *)status;

@end

typedef void (^ClaudeAPITextDeltaBlock)(NSString *text);
typedef void (^ClaudeAPICompletionBlock)(
    NSArray<NSDictionary *> *contentBlocks,
    NSString *_Nullable stopReason,
    NSError *_Nullable error);

@interface ClaudeAPIClient : NSObject <NSURLSessionDataDelegate>

- (instancetype)initWithAPIKey:(NSString *)apiKey
                         model:(NSString *)model;
- (void)streamMessages:(NSArray<NSDictionary *> *)messages
                 system:(NSString *)system
                  tools:(NSArray<NSDictionary *> *)tools
              textDelta:(ClaudeAPITextDeltaBlock)textDelta
             completion:(ClaudeAPICompletionBlock)completion;
- (void)cancel;

@end

typedef void (^ClaudeCodeCompletionBlock)(
    NSString *text,
    NSString *_Nullable sessionID,
    NSString *_Nullable model,
    NSError *_Nullable error);

@interface ClaudeCodeClient : NSObject

+ (BOOL)runStreamParsingSelfTests;
- (instancetype)initWithExecutable:(NSString *)executable
                  configDirectory:(NSString *)configDirectory
                 workingDirectory:(NSString *)workingDirectory
                            model:(NSString *)model
                        sessionID:(nullable NSString *)sessionID;
- (void)streamPrompt:(NSString *)prompt
        systemPrompt:(nullable NSString *)systemPrompt
           textDelta:(ClaudeAPITextDeltaBlock)textDelta
          completion:(ClaudeCodeCompletionBlock)completion;
- (void)cancel;

@end

NS_ASSUME_NONNULL_END
