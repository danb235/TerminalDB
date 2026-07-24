#import <AppKit/AppKit.h>

@class ClaudeProfile;
@class ClaudeProfileManager;
@class ClaudeStatusBar;
@class TerminalTheme;

NS_ASSUME_NONNULL_BEGIN

@protocol ClaudeStatusBarDelegate <NSObject>

- (void)claudeStatusBar:(ClaudeStatusBar *)statusBar
       didSelectProfile:(ClaudeProfile *)profile;
- (void)claudeStatusBarDidRequestAddProfile:(ClaudeStatusBar *)statusBar;
- (void)claudeStatusBar:(ClaudeStatusBar *)statusBar
 didRequestLoginProfile:(ClaudeProfile *)profile;

@end

@interface ClaudeStatusBar : NSView

@property(nonatomic, weak, nullable) id<ClaudeStatusBarDelegate> delegate;
@property(nonatomic, strong, readonly, nullable) ClaudeProfile *selectedProfile;
@property(nonatomic, readonly) BOOL accountIsLoggedIn;
@property(nonatomic, readonly) BOOL accountStatusKnown;

- (instancetype)initWithFrame:(NSRect)frame
             claudeExecutable:(nullable NSString *)claudeExecutable
               profileManager:(ClaudeProfileManager *)profileManager
               selectedProfile:(nullable ClaudeProfile *)selectedProfile
                         theme:(TerminalTheme *)theme;
- (void)startMonitoring;
- (void)selectProfile:(nullable ClaudeProfile *)profile;
- (void)refreshNow;
- (void)presentUsageWindow;
- (void)showEnvironment:(NSString *)environment
                   host:(nullable NSString *)host
                 detail:(nullable NSString *)detail;
+ (BOOL)runUsageNormalizationSelfTests;

@end

NS_ASSUME_NONNULL_END
