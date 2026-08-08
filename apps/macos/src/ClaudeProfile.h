#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const ClaudeProfilesDidChangeNotification;

@interface ClaudeProfile : NSObject

@property(nonatomic, copy, readonly) NSString *identifier;
@property(nonatomic, copy, readonly) NSString *label;
@property(nonatomic, copy, readonly, nullable) NSString *email;
@property(nonatomic, copy, readonly, nullable) NSString *subscriptionType;
@property(nonatomic, copy, readonly) NSString *profileDirectory;
@property(nonatomic, copy, readonly) NSString *configDirectory;
@property(nonatomic, copy, readonly) NSString *settingsPath;
@property(nonatomic, copy, readonly) NSString *statusCachePath;
@property(nonatomic, copy, readonly) NSString *statusLineCachePath;
@property(nonatomic, copy, readonly) NSString *keychainService;

@end

@interface ClaudeProfileManager : NSObject

@property(nonatomic, copy, readonly) NSArray<ClaudeProfile *> *profiles;
@property(nonatomic, strong, readonly, nullable) ClaudeProfile *lastSelectedProfile;

+ (BOOL)runStorageSelfTests;
- (nullable ClaudeProfile *)profileWithIdentifier:(NSString *)identifier;
- (nullable ClaudeProfile *)createProfileWithLabel:(NSString *)label
                                             error:(NSError **)error;
- (BOOL)removeProfile:(ClaudeProfile *)profile error:(NSError **)error;
- (void)setLastSelectedProfile:(nullable ClaudeProfile *)profile;
- (void)updateProfile:(ClaudeProfile *)profile
                email:(nullable NSString *)email
     subscriptionType:(nullable NSString *)subscriptionType;
- (void)prepareRuntimeFilesForProfile:(ClaudeProfile *)profile;
- (void)markProfileReadyForInteractiveClaude:(ClaudeProfile *)profile;

@end

NS_ASSUME_NONNULL_END
