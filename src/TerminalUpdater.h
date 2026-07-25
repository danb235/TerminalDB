#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TerminalUpdateRelease : NSObject
@property(nonatomic, copy) NSString *version;
@property(nonatomic, copy) NSString *tagName;
@property(nonatomic, copy) NSString *notes;
@property(nonatomic, strong) NSURL *zipURL;
@property(nonatomic, strong) NSURL *checksumURL;
@property(nonatomic, strong) NSURL *releaseURL;
@end

@interface TerminalUpdater : NSObject

@property(nonatomic, strong, readonly, nullable)
    TerminalUpdateRelease *availableRelease;
@property(nonatomic, readonly, getter=isChecking) BOOL checking;
@property(nonatomic, readonly, getter=isDownloading) BOOL downloading;
@property(nonatomic, copy, nullable) void (^statusDidChange)(void);

- (instancetype)initWithRepository:(NSString *)repository
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (void)checkOnLaunchIfDue;
- (void)checkForUpdatesFromWindow:(nullable NSWindow *)window;
- (void)presentAvailableUpdateFromWindow:(nullable NSWindow *)window;

+ (BOOL)isVersion:(NSString *)remote newerThan:(NSString *)current;
+ (nullable TerminalUpdateRelease *)bestReleaseFromJSONArray:(id)json;
+ (nullable NSString *)checksumForAssetNamed:(NSString *)assetName
                                     contents:(NSString *)contents;
+ (BOOL)runSelfTests;

@end

NS_ASSUME_NONNULL_END
