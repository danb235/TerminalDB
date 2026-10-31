#pragma once
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

#import "ClaudeAPI.h"
#import "ClaudeAssistantView.h"
#import "ClaudeProfile.h"
#import "ClaudeStatusBar.h"
#import "TerminalInspector.h"
#import "TerminalLedger.h"
#import "TerminalPermissions.h"
#import "TerminalProduct.h"
#import "TerminalTheme.h"
#import "TerminalUpdater.h"
#import "TerminalDBTerminal-Swift.h"
#define TerminalView TDBTerminalSurface

NS_ASSUME_NONNULL_BEGIN

@protocol TerminalTabActionTarget <NSObject>
- (void)newWindowForTab:(id)sender;
- (BOOL)terminalWindowDidRequestCancel:(NSWindow *)window;
@end

BOOL TerminalDBRunsSessionHost(void);
BOOL TerminalDBUsesPeerSessions(void);

@interface AppDelegate : NSObject <
    NSApplicationDelegate,
    NSWindowDelegate,
    NSMenuDelegate,
    TerminalTabActionTarget,
    ClaudeStatusBarDelegate,
    ClaudeAssistantViewDelegate>
+ (BOOL)runTerminalSelfTests;
@property(nonatomic, weak, nullable) AppDelegate *owner;
@property(nonatomic, strong) NSMutableArray<AppDelegate *> *windowControllers;
@property(nonatomic, copy) NSString *terminalSessionIdentifier;
@property(nonatomic, strong) NSMenu *claudeMenu;
@property(nonatomic, strong) NSMenu *viewMenu;
@property(nonatomic, strong) NSMenu *historyMenu;
@property(nonatomic, strong) ClaudeProfileManager *profileManager;
@property(nonatomic, strong) ClaudeAPIConfiguration *apiConfiguration;
@property(nonatomic, strong, nullable)
    ClaudeAPISettingsWindowController *apiSettingsController;
@property(nonatomic, strong) TerminalTheme *theme;
@property(nonatomic, strong, nullable) ClaudeProfile *selectedProfile;
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) NSView *workspaceView;
@property(nonatomic, strong) NSMutableArray<AppDelegate *> *splitControllers;
@property(nonatomic, weak, nullable) AppDelegate *embeddedSplitOwner;
@property(nonatomic) BOOL embeddedSplitVertical;
@property(nonatomic, strong) NSProgressIndicator *tabActivityIndicator;
@property(nonatomic, strong) NSTimer *tabActivityTimer;
@property(nonatomic, strong, nullable) NSDate *foregroundProcessBeganAt;
@property(nonatomic, strong, nullable) NSDate *lastPTYOutputAt;
@property(nonatomic) BOOL tabIsBusy;
@property(nonatomic) BOOL tabActivityAnimating;
@property(nonatomic, strong) NSView *terminalScrollView;
@property(nonatomic, strong) TerminalView *terminalView;
@property(nonatomic) int pty;
@property(nonatomic) pid_t shellPid;
@property(nonatomic) dispatch_source_t readSource;
@property(nonatomic, strong, nullable) ClaudeProfile *claudeLoginProfile;
@property(nonatomic) pid_t claudeLoginProcessGroup;
@property(nonatomic, strong, nullable) NSDate *claudeLoginStartedAt;
@property(nonatomic, strong, nullable)
    ClaudeProfile *claudeLoginRestartProfile;
@property(nonatomic) NSUInteger claudeLoginRestartGeneration;
@property(nonatomic, copy, nullable) NSString *reportedWindowTitle;
@property(nonatomic) NSUInteger terminalRows;
@property(nonatomic) NSUInteger terminalColumns;
@property(nonatomic) NSUInteger appliedPTYRows;
@property(nonatomic) NSUInteger appliedPTYColumns;
@property(nonatomic) BOOL controllerGeometryActive;
@property(nonatomic, copy) NSArray<NSColor *> *ansiColors;
@property(nonatomic, strong) NSColor *defaultForeground;
@property(nonatomic, strong) NSColor *defaultBackground;
@property(nonatomic) BOOL usingJetBrainsMono;
@property(nonatomic) CGFloat terminalFontSize;
@property(nonatomic) CGFloat terminalLineHeightMultiple;
@property(nonatomic, strong) ClaudeStatusBar *claudeStatusBar;
@property(nonatomic, strong) TerminalLedgerBar *ledgerBar;
@property(nonatomic, strong) TerminalLedgerStore *ledgerStore;
@property(nonatomic, strong, nullable)
    TerminalHistoryController *historyController;
@property(nonatomic, strong, nullable)
    TerminalCommandInspectorController *commandInspectorController;
@property(nonatomic, copy) NSString *activeLedgerCommand;
@property(nonatomic, copy) NSString *activeLedgerDirectory;
@property(nonatomic, strong, nullable) NSDate *activeLedgerStartedAt;
@property(nonatomic) BOOL privateSession;
@property(nonatomic) BOOL focusMode;
@property(nonatomic) BOOL commandBarHidden;
@property(nonatomic, strong) ClaudeAssistantView *assistantView;
@property(nonatomic, strong) NSView *utilityPanelView;
@property(nonatomic, strong) NSScrollView *utilityPanelScrollView;
@property(nonatomic, strong) NSTextField *utilityPanelTitleLabel;
@property(nonatomic, strong) NSButton *utilityPanelCloseButton;
@property(nonatomic) BOOL utilityPanelRestoresAssistant;
@property(nonatomic) BOOL utilityPanelUsesFullWidth;
@property(nonatomic) CGFloat utilityPanelMinimumContentHeight;
@property(nonatomic, copy, nullable) void (^utilityPanelDismissHandler)(void);
@property(nonatomic, strong) NSButton *assistantToggleButton;
@property(nonatomic, strong) NSButton *workstationsButton;
@property(nonatomic, strong) NSButton *commandBarToggleButton;
@property(nonatomic, strong)
    NSTitlebarAccessoryViewController *assistantAccessoryController;
@property(nonatomic, strong, nullable) id assistantClient;
@property(nonatomic, strong) TerminalInspector *terminalInspector;
@property(nonatomic, strong) TerminalPermissionCenter *permissionCenter;
@property(nonatomic, copy, nullable) NSDictionary *pendingExecutionApproval;
@property(nonatomic, copy, nullable) NSString *lastAIApplyPatchPath;
@property(nonatomic, strong) TerminalProductStore *productStore;
@property(nonatomic, strong) TerminalUpdater *updater;
@property(nonatomic, strong) NSMenuItem *checkForUpdatesMenuItem;
@property(nonatomic, strong, nullable)
    TerminalProductWindowController *productWindowController;
@property(nonatomic, copy, nullable) NSString *activeMonitorIdentifier;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *assistantMessages;
@property(nonatomic, copy) NSString *assistantResponse;
@property(nonatomic, copy) NSString *assistantDirectory;
@property(nonatomic, copy) NSString *assistantSystemPrompt;
@property(nonatomic) NSUInteger assistantToolIterations;
@property(nonatomic) NSUInteger assistantRequestGeneration;
@property(nonatomic, copy, nullable) NSString *assistantSubscriptionSessionID;
@property(nonatomic, copy) NSString *assistantConfigurationSignature;
@property(nonatomic, copy, nullable) NSString *claudeExecutable;
@property(nonatomic, copy) NSString *windowProfilePath;
@property(nonatomic, copy) NSString *windowRuntimeDirectory;
@property(nonatomic, copy) NSString *windowBinDirectory;
@property(nonatomic, copy) NSString *zshDotDirectory;
@property(nonatomic, copy) NSString *claudeTabStatePath;
@property(nonatomic, copy, nullable) NSString *claudeTabState;
@property(nonatomic, strong, nullable) NSDate *claudeTabStateModifiedAt;
@property(nonatomic, copy) NSString *claudeStatusLinePath;
@property(nonatomic, copy, nullable) NSString *claudeModelName;
@property(nonatomic, strong, nullable) NSDate *claudeStatusLineModifiedAt;
@property(nonatomic, copy) NSString *shellTitlePath;
@property(nonatomic, copy) NSString *shellCWDPath;
@property(nonatomic, copy) NSString *shellCommandPath;
@property(nonatomic, copy) NSString *shellExitPath;
@property(nonatomic, copy, nullable) NSString *shellReportedTitle;
@property(nonatomic, strong, nullable) NSDate *shellTitleModifiedAt;
@property(nonatomic, copy, nullable) NSString *displayedContextDirectory;
@property(nonatomic, copy, nullable) NSString *displayedContextModel;
- (void)showAssistantConfigurationRequired;
- (BOOL)assistantProviderIsReady;
- (NSString *)assistantModelDisplayName;
- (NSString *)assistantConfigurationSignatureValue;
- (NSString *)assistantSubscriptionStatus;
- (void)assistantConfigurationDidChange:(NSNotification *)notification;
- (void)showCommandHistory:(nullable id)sender;
- (void)showCommandInspectorForRecord:(NSDictionary *)record;
- (void)pasteCommandForReview:(NSString *)command;
- (void)attachRecordToAssistant:(NSDictionary *)record
                         intent:(NSString *)intent;
- (void)requestExecutionForCommand:(NSString *)command;
- (void)showProductSection:(TerminalProductSection)section;
- (void)showUtilityPanelView:(NSView *)view
                       title:(NSString *)title
                   fullWidth:(BOOL)fullWidth
              dismissHandler:(nullable void (^)(void))dismissHandler;
- (void)hideUtilityPanel:(nullable id)sender;
- (void)saveRunbookFromRecord:(NSDictionary *)record;
- (void)newTerminalSplitVertical:(BOOL)vertical;
- (void)updateUpdaterMenuItem;
- (BOOL)claudeIsForeground;
- (BOOL)claudeSupportsDirectLogin;
- (BOOL)canRestartTrackedClaudeLoginForProfile:(ClaudeProfile *)profile;
- (NSUInteger)busyTerminalCount;
- (AppDelegate *)newTerminalTabFromWindow:(nullable NSWindow *)hostWindow;
- (void)refreshPersistentTerminalContext;
- (BOOL)applyControllerColumns:(NSUInteger)columns
                              rows:(NSUInteger)rows;

@property(nonatomic, strong, nullable) TDBSessionServer *sessionServer;
@property(nonatomic, strong, nullable) TDBSessionClient *sessionClient;
@property(nonatomic, strong, nullable) TDBPeerPanel *peerPanel;
@property(nonatomic, strong, nullable) TDBSessionBrowser *sessionBrowser;
@property(nonatomic, weak, nullable) AppDelegate *peerFocusedPane;
@property(nonatomic, copy, nullable) NSDictionary *peerState;
@property(nonatomic, copy, nullable) NSString *peerTarget;
@property(nonatomic, copy, nullable) NSString *peerWorkstationName;
@property(nonatomic, copy, nullable) NSString *peerAttachSession;
@property(nonatomic, strong) NSButton *peerControlButton;
@property(nonatomic, strong, nullable) NSMutableDictionary *peerApprovals;
@property(nonatomic, strong, nullable) NSMutableData *peerSnapshot;
@property(nonatomic, copy, nullable) NSString *peerSnapshotIdentifier;
@property(nonatomic, copy, nullable) NSString *peerStartDirectory;
@property(nonatomic) BOOL peerPrivateRequested;
@property(nonatomic) BOOL peerSnapshotNeedsNormalBuffer;
@property(nonatomic, copy, nullable) NSDictionary *peerLastPublishedState;
@property(nonatomic, copy, nullable) NSDictionary *peerRestoreState;
@property(nonatomic, copy, nullable) void (^peerAfterAttach)(void);
@property(nonatomic, copy, nullable) NSArray *peerProjectCache;
- (AppDelegate *)rootController;
- (AppDelegate *)activeTerminalController;
- (AppDelegate *)createTerminalController;
- (void)presentTerminalController:(AppDelegate *)controller;
- (AppDelegate *)terminalControllerForSessionIdentifier:(NSString *)identifier;
- (NSString *)currentAssistantDirectory;
- (void)consumeTerminalData:(NSData *)data;
- (void)showAssistantPane;
- (void)writeWindowProfileFile;
- (void)beginAssistantRequestForPrompt:(NSString *)prompt;
- (void)resetAssistantConversation;
- (void)showUtilityPanelView:(NSView *)view title:(NSString *)title fullWidth:(BOOL)fullWidth dismissHandler:(void (^)(void))dismissHandler;
- (BOOL)applyControllerColumns:(NSUInteger)columns rows:(NSUInteger)rows;
- (void)beginLedgerCommand;
- (void)finishLedgerCommand;
- (NSString *)terminalANSISnapshot;
- (NSDictionary *)remoteUsageForProfile:(ClaudeProfile *)profile;
- (void)requestExecutionForCommand:(NSString *)command;
- (void)startShell;
- (void)updateWindowTitle;
- (void)trimAssistantConversationIfNeeded;
- (BOOL)hasForegroundProcessInThisPane;
- (void)updatePTYWindowSize;
- (void)startClaudeLoginForProfile:(ClaudeProfile *)profile;
- (NSString *)shellQuotedString:(NSString *)value;
@end

@interface AppDelegate (PeerIntegration)
- (void)startSessionHost;
- (void)connectToWorkstation;
- (void)publishPeerState;
- (NSDictionary *)peerSessionState;
- (void)openPeerAccountTab:(NSString *)accountID login:(BOOL)login;
- (void)showWorkstationMenu:(id)sender;
- (void)resumePeerSession:(id)sender;
- (void)showSessionsOnWorkstation:(NSString *)target;
- (AppDelegate *)openPeerTabOn:(NSString *)target name:(NSString *)name session:(nullable NSString *)session directory:(nullable NSString *)directory private:(BOOL)privateSession window:(nullable NSWindow *)window;
- (NSWindow *)peerPresentationWindow;
- (NSString *)peerWorkstationLabel;
- (void)refreshPeerToolbar;
- (void)takePeerControl:(id)sender;
- (void)endPeerSession:(id)sender;
- (void)handlePeerHostRequest:(NSDictionary *)request reply:(void (^)(NSDictionary *))reply;
- (void)acceptPeerEvent:(NSDictionary *)event;
- (void)showPeerError:(NSString *)message;
- (void)requestPeerExecution:(NSString *)command;
@end

NS_ASSUME_NONNULL_END
