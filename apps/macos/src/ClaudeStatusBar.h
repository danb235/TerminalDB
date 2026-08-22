#import <AppKit/AppKit.h>

@class ClaudeProfile;
@class ClaudeProfileManager;
@class ClaudeStatusBar;
@class TerminalTheme;

NS_ASSUME_NONNULL_BEGIN

@protocol ClaudeStatusBarDelegate <NSObject>

- (void)claudeStatusBar:(ClaudeStatusBar *)statusBar
       didSelectProfile:(nullable ClaudeProfile *)profile;
- (void)claudeStatusBarDidRequestAddProfile:(ClaudeStatusBar *)statusBar;
- (void)claudeStatusBar:(ClaudeStatusBar *)statusBar
 didRequestLoginProfile:(ClaudeProfile *)profile;
- (void)claudeStatusBar:(ClaudeStatusBar *)statusBar
 didRequestRemoveProfile:(ClaudeProfile *)profile;
- (void)claudeStatusBarDidRequestUsagePanel:(ClaudeStatusBar *)statusBar;

@end

@interface ClaudeStatusBar : NSView

@property(nonatomic, weak, nullable) id<ClaudeStatusBarDelegate> delegate;
@property(nonatomic, strong, readonly, nullable) ClaudeProfile *selectedProfile;
@property(nonatomic, readonly) BOOL accountIsLoggedIn;
@property(nonatomic, readonly) BOOL accountStatusKnown;
@property(nonatomic, strong, readonly, nullable) NSView *usagePanelView;
@property(nonatomic, copy, nullable) void (^usagePanelDismissHandler)(void);

- (instancetype)initWithFrame:(NSRect)frame
             claudeExecutable:(nullable NSString *)claudeExecutable
               profileManager:(ClaudeProfileManager *)profileManager
               selectedProfile:(nullable ClaudeProfile *)selectedProfile
                         theme:(TerminalTheme *)theme;
- (void)startMonitoring;
- (void)selectProfile:(nullable ClaudeProfile *)profile;
- (void)refreshNow;
- (void)presentUsageWindow;
- (NSView *)prepareUsagePanel;
- (void)refreshUsageDashboard;
- (void)didDismissUsagePanel;
- (void)showEnvironment:(NSString *)environment
                   host:(nullable NSString *)host
                 detail:(nullable NSString *)detail;
- (void)showDirectory:(NSString *)directory
                model:(nullable NSString *)model;
- (void)showPasteReceiptWithByteCount:(NSUInteger)byteCount
                            lineCount:(NSUInteger)lineCount;
+ (BOOL)runUsageNormalizationSelfTests;

@end

NS_ASSUME_NONNULL_END
