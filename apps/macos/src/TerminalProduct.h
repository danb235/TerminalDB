#import <AppKit/AppKit.h>

@class TerminalTheme;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, TerminalProductSection) {
    TerminalProductSectionProject = 0,
    TerminalProductSectionEnvironments,
    TerminalProductSectionMonitor,
    TerminalProductSectionRunbooks,
    TerminalProductSectionWorkspaces,
    TerminalProductSectionSettings,
    TerminalProductSectionOnboarding,
};

@interface TerminalProductStore : NSObject

@property(nonatomic, copy, readonly) NSArray<NSDictionary *> *runbooks;
@property(nonatomic, copy, readonly) NSArray<NSDictionary *> *workspaces;
@property(nonatomic, copy, readonly) NSArray<NSDictionary *> *monitors;

+ (instancetype)sharedStore;
+ (instancetype)ephemeralStoreForTesting;
- (NSDictionary *)saveRunbookNamed:(NSString *)name
                           command:(NSString *)command
                         directory:(NSString *)directory;
- (void)updateRunbookWithIdentifier:(NSString *)identifier
                               name:(NSString *)name
                            command:(NSString *)command
                          directory:(NSString *)directory;
- (void)markRunbookExecuted:(NSString *)identifier;
- (void)deleteRunbookWithIdentifier:(NSString *)identifier;
- (NSDictionary *)saveWorkspaceNamed:(NSString *)name
                           directory:(NSString *)directory
                      accountLabel:(nullable NSString *)accountLabel
                          chatTitle:(nullable NSString *)chatTitle;
- (NSDictionary *)saveWorkspaceNamed:(NSString *)name
                            snapshot:(NSDictionary *)snapshot;
- (void)renameWorkspaceWithIdentifier:(NSString *)identifier
                                  name:(NSString *)name;
- (void)deleteWorkspaceWithIdentifier:(NSString *)identifier;
- (NSString *)beginMonitoringCommand:(NSString *)command
                           directory:(NSString *)directory
                         environment:(NSString *)environment;
- (void)finishMonitorWithIdentifier:(NSString *)identifier
                           exitCode:(NSInteger)exitCode
                             output:(NSString *)output;
- (void)removeMonitorWithIdentifier:(NSString *)identifier;
- (BOOL)runSelfTests;

@end

@interface TerminalProductWindowController : NSWindowController

@property(nonatomic, copy, nullable) void (^runCommandHandler)(NSString *command);
@property(nonatomic, copy, nullable) void (^pasteCommandHandler)(NSString *command);
@property(nonatomic, copy, nullable) void (^restoreWorkspaceHandler)(
    NSDictionary *workspace);
@property(nonatomic, copy, nullable) void (^openAPISettingsHandler)(void);
@property(nonatomic, copy, nullable) void (^newAIChatHandler)(void);
@property(nonatomic, copy, nullable) void (^addClaudeAccountHandler)(void);
@property(nonatomic, copy, nullable) void (^showHistoryHandler)(void);
@property(nonatomic, copy, nullable) void (^activateTerminalHandler)(void);
@property(nonatomic, copy, nullable) void (^askAIHandler)(
    NSDictionary *context, NSString *prompt);
@property(nonatomic, copy, nullable) NSDictionary *
    (^workspaceSnapshotProvider)(void);

+ (BOOL)runWindowSelfTestsWithTheme:(TerminalTheme *)theme
                               store:(TerminalProductStore *)store;
- (instancetype)initWithTheme:(TerminalTheme *)theme
                         store:(TerminalProductStore *)store;
- (void)showSection:(TerminalProductSection)section
          directory:(NSString *)directory
       accountLabel:(nullable NSString *)accountLabel;
- (void)promptToSaveCurrentWorkspace;
- (void)refresh;

@end

NS_ASSUME_NONNULL_END
