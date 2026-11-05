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
- (void)claudeStatusBarDidRequestAWSAccounts:(ClaudeStatusBar *)statusBar;
- (void)claudeStatusBar:(ClaudeStatusBar *)statusBar didRequestSharedSignIn:(nullable ClaudeProfile *)profile;
- (void)claudeStatusBarDidRequestAccountSync:(ClaudeStatusBar *)statusBar;

@end

@interface ClaudeStatusBar : NSView

@property(nonatomic, weak, nullable) id<ClaudeStatusBarDelegate> delegate;
@property(nonatomic, strong, readonly, nullable) ClaudeProfile *selectedProfile;
@property(nonatomic, readonly) BOOL accountIsLoggedIn;
@property(nonatomic, readonly) BOOL accountStatusKnown;
@property(nonatomic, strong, readonly, nullable) NSView *usagePanelView;
@property(nonatomic, copy, nullable) void (^usagePanelDismissHandler)(void);
@property(nonatomic) BOOL peerMode;
@property(nonatomic, copy) NSString *accountWorkstationName;
@property(nonatomic, copy, nullable) void (^peerRefreshHandler)(void);
- (NSDictionary *)peerUsagePresentation;
- (void)applyPeerState:(NSDictionary *)state;
- (void)applyAWSStatus:(NSDictionary *)snapshot;

- (instancetype)initWithFrame:(NSRect)frame
             claudeExecutable:(nullable NSString *)claudeExecutable
               profileManager:(ClaudeProfileManager *)profileManager
               selectedProfile:(nullable ClaudeProfile *)selectedProfile
                         theme:(TerminalTheme *)theme;
- (void)startMonitoring;
- (void)selectProfile:(nullable ClaudeProfile *)profile;
- (void)refreshNow;
- (void)presentUsageWindow;
- (void)presentAccountPicker;
- (void)accountSelectionDidComplete:(BOOL)accepted;
- (NSView *)prepareUsagePanel;
- (NSView *)prepareEmbeddedAccountsView;
- (void)refreshUsageDashboard;
- (void)dismissUsagePanel:(nullable id)sender;
- (void)didDismissUsagePanel;
- (void)showEnvironment:(NSString *)environment
                   host:(nullable NSString *)host
                 detail:(nullable NSString *)detail;
- (void)showDirectory:(NSString *)directory
                model:(nullable NSString *)model;
- (void)showPasteReceiptWithByteCount:(NSUInteger)byteCount
                            lineCount:(NSUInteger)lineCount;
+ (BOOL)runUsageNormalizationSelfTests;
+ (BOOL)runInterfaceSelfTests;

@end

NS_ASSUME_NONNULL_END
