#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const ClaudeAPIConfigurationDidChangeNotification;

@interface ClaudeAPIConfiguration : NSObject

@property(nonatomic, readonly) BOOL hasAPIKey;
@property(nonatomic, copy, readonly) NSArray<NSDictionary *> *models;
@property(nonatomic, copy, readonly, nullable) NSString *selectedModelID;

- (nullable NSString *)apiKey;
- (BOOL)saveAPIKey:(NSString *)apiKey error:(NSError **)error;
- (BOOL)removeAPIKeyWithError:(NSError **)error;
- (void)selectModelID:(NSString *)modelID;
- (NSString *)displayNameForModelID:(NSString *)modelID;
- (void)refreshModelsWithCompletion:
    (void (^)(NSArray<NSDictionary *> *models, NSError *_Nullable error))completion;

@end

@interface ClaudeAPISettingsWindowController : NSWindowController

- (instancetype)initWithConfiguration:
    (ClaudeAPIConfiguration *)configuration;
- (void)present;

@end

typedef void (^ClaudeAPITextDeltaBlock)(NSString *text);
typedef void (^ClaudeAPICompletionBlock)(NSError *_Nullable error);

@interface ClaudeAPIClient : NSObject <NSURLSessionDataDelegate>

- (instancetype)initWithAPIKey:(NSString *)apiKey
                         model:(NSString *)model;
- (void)streamMessages:(NSArray<NSDictionary *> *)messages
                 system:(NSString *)system
              textDelta:(ClaudeAPITextDeltaBlock)textDelta
             completion:(ClaudeAPICompletionBlock)completion;
- (void)cancel;

@end

NS_ASSUME_NONNULL_END
